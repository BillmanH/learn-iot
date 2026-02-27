# Arc RBAC & Custom-Locations: Gap Diagnosis & Troubleshooting

## The Core Problem

The `Az.ConnectedKubernetes` PowerShell module has **two separate gaps** that affect IoT Operations deployment:

| Feature | PS Module Behavior | What Actually Needs to Happen |
|---|---|---|
| `custom-locations` | Sets flag in Azure ARM only | Must ALSO run `helm upgrade` on the cluster |
| `azure-rbac` | Parameter **renamed** to `AadProfileEnableAzureRbac` in v0.11+; old name silently ignored | Must ALSO deploy guard webhook pods |
| `workload-identity` | Sets ARM flag only | Must ALSO deploy webhook pods to the cluster |
| `Feature` property | **Does not exist** on `ConnectedCluster` object in 0.15.0 | Cannot check custom-locations state via PS object at all — use Helm |

> **Confirmed on 2026-02-27 with Az.ConnectedKubernetes 0.15.0:**
> - `AzureRbacEnabled` renamed to `AadProfileEnableAzureRbac` (flat property, NOT nested under `AadProfile`)
> - `ConnectedCluster` object has **no `.Feature` property** — any loop over `$arc.Feature` is a silent no-op
> - Custom-locations state **cannot be read from the PS object** — Helm is the only reliable check
> - Script has been fixed to use Helm for custom-locations idempotency checks

The script (`arc_enable.ps1`) works around these by calling Azure CLI (`az connectedk8s`) after the PS module. This document helps you **verify each layer** — ARM state, Helm state, and pod state — to confirm which steps succeeded and which did not.

---

## Step 1: Validate the PowerShell Module Has the Right Parameters

Run these on the **edge machine** (where the PS module is installed). These confirm the module version and which parameters it exposes — helpful to know if the script's splatted `@connectParams` will work at all.

```powershell
# What version is installed?
Get-Module Az.ConnectedKubernetes -ListAvailable | Select-Object Name, Version, Path

# Does New-AzConnectedKubernetes accept the params the script passes?
(Get-Command New-AzConnectedKubernetes).Parameters.Keys | Sort-Object

# Key params the script needs - check these specifically (CONFIRMED correct names for 0.15.0):
foreach ($param in @('CustomLocationsOid','AadProfileEnableAzureRbac','WorkloadIdentityEnabled','OidcIssuerProfileEnabled','PrivateLinkState')) {
    $has = (Get-Command New-AzConnectedKubernetes).Parameters.ContainsKey($param)
    Write-Host "$param : $has" -ForegroundColor $(if ($has) {"Green"} else {"Red"})
}

# NOTE: In older docs/scripts you may see 'AzureRbacEnabled' - this was RENAMED to 'AadProfileEnableAzureRbac' in v0.11+
# Using the old name is silently ignored (no error, RBAC just never gets set)

# Check Set-AzConnectedKubernetes - same rename applies:
foreach ($param in @('AadProfileEnableAzureRbac','WorkloadIdentityEnabled','OidcIssuerProfileEnabled')) {
    $has = (Get-Command Set-AzConnectedKubernetes).Parameters.ContainsKey($param)
    Write-Host "Set-Az | $param : $has" -ForegroundColor $(if ($has) {"Green"} else {"Red"})
}

# If you're unsure, dump all RBAC/AAD/Identity-related params for both cmdlets:
(Get-Command New-AzConnectedKubernetes).Parameters.Keys | Sort-Object | Where-Object { $_ -match "Rbac|Identity|Oidc|Auth|Feature|Aad" }
(Get-Command Set-AzConnectedKubernetes).Parameters.Keys | Sort-Object | Where-Object { $_ -match "Rbac|Identity|Oidc|Auth|Feature|Aad" }
```

**Expected output** (all `True`). Validated against 0.15.0 — uses `AadProfileEnableAzureRbac`, not `AzureRbacEnabled`.

If any are `False`, the module may need updating:

```powershell
Install-Module Az.ConnectedKubernetes -Scope CurrentUser -Force -AllowClobber
```

---

## Step 2: ARM State — What Azure Thinks Is Enabled

These commands query the Azure control plane. This is the "ARM layer" — what the PS module writes to.

```bash
# Replace with your values from config/aio_config.json
CLUSTER="<your-cluster-name>"
RG="<your-resource-group>"

# Full feature state as seen by ARM
az connectedk8s show \
  --name $CLUSTER \
  --resource-group $RG \
  --query '{
    connectivity: connectivityStatus,
    privateLinkState: privateLinkState,
    azureRbac: aadProfile.enableAzureRbac,
    workloadIdentity: workloadIdentityEnabled,
    oidcIssuer: oidcIssuerProfile.issuerUrl,
    features: features[].{name:name, state:state}
  }' \
  --output json
```

**What to look for:**

| Field | Expected Value | Problem if not |
|---|---|---|
| `connectivity` | `"Connected"` | Arc agents not healthy — check `kubectl get pods -n azure-arc` |
| `privateLinkState` | `"Disabled"` | **Critical**: Private Link breaks custom-locations. Must delete and re-Arc |
| `azureRbac` | `true` | RBAC not registered in ARM — run `az connectedk8s enable-features` (field is `aadProfile.enableAzureRbac` in ARM JSON) |
| `workloadIdentityEnabled` | `true` | Workload identity not in ARM |
| `oidcIssuer` | An `https://oidc.prod-aks.azure.com/...` URL | OIDC not enabled — needed for secret sync |
| `features[].custom-locations.state` | `"Installed"` or `"Enabled"` | ARM flag set but may not mean Helm is updated |

> **Note:** ARM showing `true` does NOT mean the cluster is configured. Continue to Step 3 to verify the cluster itself.

---

## Step 3: Helm State — What's Actually in the Cluster (Authoritative for Custom-Locations)

The ARM API for custom-locations is unreliable. The Helm values are the **authoritative source**.

```bash
# Is custom-locations enabled in the actual Arc Helm chart?
helm get values azure-arc --namespace azure-arc-release -o json \
  | jq '.systemDefaultValues.customLocations'

# Expected output:
# {
#   "enabled": true,
#   "oid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# }
```

**If `enabled` is `false` or missing**, the PS module registered custom-locations in ARM but the `helm upgrade` step was skipped. This is the known gap. Fix:

```bash
# Get the Custom Locations RP OID
CUSTOM_LOC_OID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)

# Enable via CLI (this does BOTH ARM registration AND helm upgrade)
az connectedk8s enable-features \
  --name $CLUSTER \
  --resource-group $RG \
  --features cluster-connect custom-locations \
  --custom-locations-oid $CUSTOM_LOC_OID

# Verify
helm get values azure-arc --namespace azure-arc-release -o json \
  | jq '.systemDefaultValues.customLocations'
```

---

## Step 4: Pod State — Are the Feature Webhooks Running?

Azure RBAC and Workload Identity both require webhook pods running in `azure-arc`. ARM/Helm state is not enough.

```bash
# Full pod list for azure-arc - the reference view
kubectl get pods -n azure-arc

# Expected healthy pods (not exhaustive, but key ones):
kubectl get pods -n azure-arc | grep -E \
  "NAME|cluster-identity|config-agent|extension-manager|guard|kube-aad-proxy|metrics-agent|resource-sync|workload-identity"
```

### 4a. Azure RBAC — guard / kube-aad-proxy

```bash
# These pods enable kubectl proxy access via Azure RBAC
kubectl get pods -n azure-arc | grep -E "guard|kube-aad-proxy"
```

If missing, Azure RBAC wasn't deployed to the cluster (ARM may still say `azureRbacEnabled: true`). Fix:

```bash
az connectedk8s enable-features \
  --name $CLUSTER \
  --resource-group $RG \
  --features azure-rbac
```

### 4b. Workload Identity Webhook

```bash
# This webhook is required for Key Vault secret sync to work
kubectl get pods -n azure-arc | grep workload-identity
```

If missing, the PS module set the ARM flag but didn't deploy the webhook. Fix:

```bash
az connectedk8s update \
  --name $CLUSTER \
  --resource-group $RG \
  --enable-workload-identity

# Wait ~30s then verify
sleep 30
kubectl get pods -n azure-arc | grep workload-identity
```

---

## Step 5: OIDC Issuer — Does K3s Match Azure?

Secret sync will fail with `AADSTS700211: No matching federated identity record found` if K3s is still using its default issuer.

```bash
# What issuer is K3s currently using?
kubectl cluster-info dump 2>/dev/null | grep service-account-issuer

# What issuer does Azure expect?
az connectedk8s show \
  --name $CLUSTER \
  --resource-group $RG \
  --query "oidcIssuerProfile.issuerUrl" \
  --output tsv
```

They must match. If they don't, see [Configure-K3sOidcIssuer in arc_enable.ps1](../arc_build_linux/arc_enable.ps1) — the script will update `/etc/rancher/k3s/config.yaml` and restart K3s.

---

## Step 6: Custom Locations CRD — Is AIO Ready to Deploy?

After custom-locations is enabled, the custom location resource itself must exist before `az iot ops init` is run.

```bash
# Does the custom location exist?
kubectl get customlocations -A

# Do the required CRDs exist?
kubectl get crd | grep customlocations

# Check the custom location's sync status
kubectl describe customlocations -A
```

---

## Quick Reference: Manual Fix Commands

Run these on the edge machine when `arc_enable.ps1` reports a warning but doesn't fix it automatically.

```bash
CLUSTER="<your-cluster-name>"
RG="<your-resource-group>"
CUSTOM_LOC_OID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)

# Fix 1: Enable custom-locations (ARM + Helm)
az connectedk8s enable-features \
  --name $CLUSTER --resource-group $RG \
  --features cluster-connect custom-locations \
  --custom-locations-oid $CUSTOM_LOC_OID

# Fix 2: Enable Azure RBAC
az connectedk8s enable-features \
  --name $CLUSTER --resource-group $RG \
  --features azure-rbac

# Fix 3: Deploy workload identity webhook
az connectedk8s update \
  --name $CLUSTER --resource-group $RG \
  --enable-workload-identity

# Verify everything in one shot
echo "--- ARM State ---"
az connectedk8s show --name $CLUSTER --resource-group $RG \
  --query '{rbac:aadProfile.enableAzureRbac, wi:workloadIdentityEnabled, oidc:oidcIssuerProfile.issuerUrl, features:features[].{n:name,s:state}}' \
  -o json

echo ""
echo "--- Helm custom-locations ---"
helm get values azure-arc --namespace azure-arc-release -o json \
  | jq '.systemDefaultValues.customLocations'

echo ""
echo "--- azure-arc pods ---"
kubectl get pods -n azure-arc
```

---

## Diagnostic Checklist

Use this before each run of `arc_enable.ps1` to know what to expect:

- [ ] PS module version is recent (`Az.ConnectedKubernetes >= 0.8.0`)
- [ ] `New-AzConnectedKubernetes` has `CustomLocationsOid` parameter
- [ ] `New-AzConnectedKubernetes` has `AadProfileEnableAzureRbac` parameter (NOT `AzureRbacEnabled` — that name was retired)
- [ ] `Set-AzConnectedKubernetes` has `AadProfileEnableAzureRbac` parameter
- [ ] Do NOT rely on `$arc.Feature` — that property does not exist; use Helm for custom-locations state
- [ ] ARM: `privateLinkState` is `"Disabled"`
- [ ] ARM: `connectivityStatus` is `"Connected"`
- [ ] Helm: `systemDefaultValues.customLocations.enabled` is `true`
- [ ] Pods: `guard` / `kube-aad-proxy` running in `azure-arc`
- [ ] Pods: `workload-identity-webhook` running in `azure-arc`
- [ ] K3s `service-account-issuer` matches Arc OIDC issuer URL

---

## Related Issues

- [issues/secret_sync_issue.md](secret_sync_issue.md) — downstream symptom when workload identity webhook is missing
- [issues/fabric_entra_id_gap.md](fabric_entra_id_gap.md) — SASL auth requirement for Fabric endpoints
- [KEYVAULT_INTEGRATION.md](../docs/KEYVAULT_INTEGRATION.md) — Key Vault secret sync setup
- Known Issue in [copilot-instructions.md](../.github/copilot-instructions.md): `Az.ConnectedKubernetes -CustomLocationsOid Gap` and `-WorkloadIdentityEnabled Gap`
