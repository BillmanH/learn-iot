# ==============================================================================
# post-provision.ps1
# Runs after `azd provision` (Bicep deployment) completes.
#
# Steps:
#   1.  Wait for VM cloud-init bootstrap to complete (/tmp/k3s-ready)
#   2.  Connect K3s cluster to Azure Arc (runs ON the VM via run-command with MSI auth)
#   3.  Reconfigure K3s OIDC issuer (get Arc issuer URL, update K3s config, restart K3s)
#   4.  Enable custom-locations + cluster-connect (runs ON VM via run-command; CLI updates Helm)
#   5.  Enable workload identity webhook (az connectedk8s update from Windows, waits for pods)
#   6.  Grant Key Vault Secrets User to Arc cluster identity (dynamic role assignment)
#   7.  Run `az iot ops init` (Arc extensions + cert-manager)
#   8.  Run `az iot ops create` (deploy AIO instance, includes --ns-resource-id for AIO v1.2+)
#   9.  Enable AIO secret sync (az iot ops secretsync enable with correct --name flag)
#  10.  Grant Key Vault Secrets User to AIO instance identity (dynamic role assignment)
#  11.  Seed placeholder secrets in Key Vault
#  12.  Optional: deploy edge modules
#
# Known workarounds applied:
#   - Arc connect uses `az vm run-command invoke` (no SSH required, Entra ID auth)
#   - Custom-locations uses Azure CLI enable-features (updates both ARM and Helm in cluster)
#   - Workload identity uses `az connectedk8s update` (deploys the webhook DaemonSet)
#   - Secretsync uses --name <instance> NOT --cluster (correct AIO CLI signature)
#   - Arc cluster identity and AIO instance identity KV grants are dynamic (post-connect/create)
# ==============================================================================

param(
    [switch]$SkipArc,      # Skip Arc connection (useful if cluster already Arc-enabled)
    [switch]$SkipAio,      # Skip AIO install (Bicep-only run)
    [switch]$SkipModules,  # Skip module deployment even if flags are set
    [switch]$DryRun        # Print commands without executing them
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Write-Step  { param([string]$Msg) Write-Host "`n--- $Msg ---" -ForegroundColor Cyan }
function Write-OK    { param([string]$Msg) Write-Host "  [OK] $Msg"   -ForegroundColor Green }
function Write-Info  { param([string]$Msg) Write-Host "  [..] $Msg" }
function Write-Warn  { param([string]$Msg) Write-Host "  [!!] $Msg"   -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Load azd environment
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================"
Write-Host "===         Post-Provision Hook              ==="
Write-Host "================================================"
Write-Host ""
Write-Info "Loading azd environment values..."

$azdEnv = (azd env get-values --output json 2>$null | ConvertFrom-Json -AsHashtable)
if (-not $azdEnv) {
    Write-Error "Could not load azd environment. Run 'azd up' from the repo root or azd-deploy/ directory."
    exit 1
}

$subscriptionId   = $azdEnv['AZURE_SUBSCRIPTION_ID']
$resourceGroup    = $azdEnv['AZURE_RESOURCE_GROUP']
$location         = $azdEnv['AZURE_LOCATION']
$vmName           = $azdEnv['AZURE_VM_NAME']
$clusterName      = $azdEnv['AIO_CLUSTER_NAME']
$kvName           = $azdEnv['AIO_KEY_VAULT_NAME']
$kvUri            = $azdEnv['AIO_KEY_VAULT_URI']
$schemaRegistry   = $azdEnv['AIO_SCHEMA_REGISTRY_NAME']
$managedIdName    = $azdEnv['AIO_MANAGED_IDENTITY_NAME']
$managedIdClient  = $azdEnv['AIO_MANAGED_IDENTITY_CLIENT_ID']
$acrServer        = $azdEnv['AZURE_CONTAINER_REGISTRY_LOGIN_SERVER']
$drNamespaceId    = $azdEnv['AIO_DEVICE_REGISTRY_NAMESPACE_ID']

# Derived values
$instanceName  = "${clusterName}-aio"
$kvResourceId  = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$kvName"
$miResourceId  = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$managedIdName"

# Key Vault Secrets User role definition ID (built-in, stable across all tenants)
$kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

Write-Host ""
Write-Info "Resource Group  : $resourceGroup"
Write-Info "VM Name         : $vmName"
Write-Info "Cluster Name    : $clusterName"
Write-Info "AIO Instance    : $instanceName"
Write-Info "Key Vault       : $kvName"
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: run a bash script on the VM via az vm run-command invoke.
# Writes the script to a temp file and passes it with the @file syntax.
# Returns the raw az output object so callers can inspect stdout/stderr.
# ---------------------------------------------------------------------------
function Invoke-VmScript {
    param(
        [string]$Description,
        [string]$BashScript
    )
    Write-Info "VM > $Description"
    if ($DryRun) { Write-Warn "[DryRun] Would run bash script on VM"; return $null }

    $tmpFile = [System.IO.Path]::GetTempFileName() + ".sh"
    try {
        Set-Content -Path $tmpFile -Value $BashScript -Encoding UTF8

        $result = az vm run-command invoke `
            --resource-group $resourceGroup `
            --name $vmName `
            --command-id RunShellScript `
            --scripts "@$tmpFile" `
            --output json | ConvertFrom-Json
    }
    finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    $stdout = $result.value[0].message
    $stderr = $result.value[1].message
    if ($stdout -and $stdout.Trim())                          { Write-Host $stdout }
    if ($stderr -and $stderr.Trim() -match '\S')              { Write-Warn "VM stderr: $stderr" }
    return $result
}

# ===========================================================================
# STEP 1 — Wait for cloud-init bootstrap
# ===========================================================================
Write-Step "Step 1/12: Waiting for cloud-init bootstrap (/tmp/k3s-ready)"

$maxWait  = 1200   # 20 minutes — VM provisioning + K3s install + CSI driver install
$elapsed  = 0
$interval = 30

Write-Info "Polling VM every ${interval}s (timeout: ${maxWait}s)..."

while ($elapsed -lt $maxWait) {
    if (-not $DryRun) {
        $pollResult = az vm run-command invoke `
            --resource-group $resourceGroup `
            --name $vmName `
            --command-id RunShellScript `
            --scripts "test -f /tmp/k3s-ready && echo K3S_READY || echo K3S_NOT_READY" `
            --output json 2>$null | ConvertFrom-Json

        if ($pollResult.value[0].message -match 'K3S_READY') {
            Write-OK "Cloud-init complete — K3s is ready."
            break
        }
    } else {
        Write-Warn "[DryRun] Skipping cloud-init poll"
        break
    }

    Write-Info "Not ready yet (${elapsed}s elapsed) — waiting ${interval}s..."
    Start-Sleep -Seconds $interval
    $elapsed += $interval
}

if (-not $DryRun -and $elapsed -ge $maxWait) {
    Write-Error "Timed out waiting for cloud-init. Check VM boot diagnostics in the Azure portal."
}

if (-not $SkipArc) {

    # =======================================================================
    # STEP 2 — Connect K3s cluster to Azure Arc
    #
    # Runs ON the VM via az vm run-command (no SSH required).
    # The VM has:
    #   - Azure CLI installed by cloud-init
    #   - A system-assigned managed identity (az login --identity)
    #   - K3s kubeconfig at /etc/rancher/k3s/k3s.yaml (accessible to root)
    #   - API server at 127.0.0.1:6443 (accessible only from the VM itself)
    #
    # Flags used:
    #   --enable-oidc-issuer       : Required for workload identity and secret sync
    #   --enable-workload-identity : Registers feature with ARM (webhook deployed in Step 5)
    # =======================================================================
    Write-Step "Step 2/12: Connecting K3s cluster to Azure Arc"

    $arcConnectScript = @"
#!/bin/bash
set -e
echo "[ARC CONNECT] Logging in with VM managed identity..."
az login --identity --output none

echo "[ARC CONNECT] Setting subscription..."
az account set --subscription $subscriptionId --output none

echo "[ARC CONNECT] Checking if cluster already Arc-connected..."
if az connectedk8s show --name "$clusterName" --resource-group "$resourceGroup" --output none 2>/dev/null; then
    echo "[ARC CONNECT] Cluster '$clusterName' is already Arc-connected - skipping."
    exit 0
fi

echo "[ARC CONNECT] Connecting cluster to Azure Arc (this may take 3-5 minutes)..."
az connectedk8s connect \
    --name "$clusterName" \
    --resource-group "$resourceGroup" \
    --location "$location" \
    --subscription "$subscriptionId" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --output none

echo "[ARC CONNECT] Done."
"@

    Invoke-VmScript -Description "az connectedk8s connect (with OIDC + workload identity)" -BashScript $arcConnectScript

    Write-Info "Waiting 30s for Arc agent to initialise in the cluster..."
    if (-not $DryRun) { Start-Sleep -Seconds 30 }

    # =======================================================================
    # STEP 3 — Reconfigure K3s with the Arc OIDC issuer URL
    #
    # `az connectedk8s connect --enable-oidc-issuer` creates an OIDC discovery
    # endpoint in Azure for the cluster. But K3s still issues service account
    # tokens with its DEFAULT issuer (https://kubernetes.default.svc.cluster.local).
    # Azure federated identity credentials expect the Arc-issued URL, so secret
    # sync fails with AADSTS700211 unless K3s is reconfigured.
    #
    # Fix: read the Arc OIDC issuer URL from Azure, write it to
    # /etc/rancher/k3s/config.yaml, restart K3s, wait for ready.
    #
    # Ref: Known issue in copilot-instructions.md
    #      — Az.ConnectedKubernetes WorkloadIdentityEnabled gap
    # =======================================================================
    Write-Step "Step 3/12: Reconfiguring K3s OIDC issuer (required for secret sync)"

    if (-not $DryRun) {
        Write-Info "Fetching Arc OIDC issuer URL from Azure..."
        $maxOidcWait = 120
        $oidcElapsed = 0
        $oidcIssuerUrl = $null

        while ($oidcElapsed -lt $maxOidcWait) {
            $oidcIssuerUrl = az connectedk8s show `
                --name $clusterName `
                --resource-group $resourceGroup `
                --query "oidcIssuerProfile.issuerUrl" -o tsv 2>$null
            if ($oidcIssuerUrl) { break }
            Write-Info "OIDC issuer URL not yet available (${oidcElapsed}s) — waiting 15s..."
            Start-Sleep -Seconds 15
            $oidcElapsed += 15
        }

        if (-not $oidcIssuerUrl) {
            Write-Error "Arc OIDC issuer URL not available after ${maxOidcWait}s. Secret sync will fail. Re-run with -SkipArc after cluster stabilises."
        }

        Write-Info "Arc OIDC issuer URL: $oidcIssuerUrl"

        $k3sOidcScript = @"
#!/bin/bash
set -e
OIDC_ISSUER_URL="$oidcIssuerUrl"
CONFIG_PATH="/etc/rancher/k3s/config.yaml"

echo "[K3S-OIDC] Configuring K3s service-account-issuer..."
echo "[K3S-OIDC] Issuer URL: \$OIDC_ISSUER_URL"

# Check if already configured with the correct issuer
if grep -q "service-account-issuer=\$OIDC_ISSUER_URL" "\$CONFIG_PATH" 2>/dev/null; then
    echo "[K3S-OIDC] K3s already configured with correct issuer - skipping restart."
    exit 0
fi

# Preserve any existing config entries (sysctl args etc), append OIDC block
if [ -f "\$CONFIG_PATH" ] && grep -q "service-account-issuer" "\$CONFIG_PATH"; then
    # Replace existing issuer line
    sed -i "s|service-account-issuer=.*|service-account-issuer=\$OIDC_ISSUER_URL|g" "\$CONFIG_PATH"
else
    # Append OIDC args to existing config (or create new file)
    cat >> "\$CONFIG_PATH" << EOF

kube-apiserver-arg:
  - 'service-account-issuer=\$OIDC_ISSUER_URL'
  - 'service-account-max-token-expiration=24h'
EOF
fi

echo "[K3S-OIDC] Restarting K3s to apply OIDC issuer..."
sudo systemctl restart k3s

echo "[K3S-OIDC] Waiting for K3s to become ready (up to 90s)..."
ATTEMPTS=0
until kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready '; do
    sleep 5
    ATTEMPTS=\$((ATTEMPTS + 1))
    if [ \$ATTEMPTS -ge 18 ]; then
        echo "[K3S-OIDC] ERROR: K3s did not become ready after restart."
        exit 1
    fi
done

echo "[K3S-OIDC] K3s ready. Verifying issuer..."
kubectl cluster-info dump 2>/dev/null | grep -o "service-account-issuer=[^ ,\"]*" | head -1 || echo "(grep inconclusive - continuing)"
echo "[K3S-OIDC] Done."
"@

        Invoke-VmScript -Description "Configure K3s OIDC issuer + restart K3s" -BashScript $k3sOidcScript
    } else {
        Write-Warn "[DryRun] Would configure K3s service-account-issuer with Arc OIDC URL and restart K3s"
    }
    Write-OK "K3s OIDC issuer configured."

    # =======================================================================
    # STEP 4 — Enable custom-locations + cluster-connect features
    #
    # CRITICAL: Must run ON the VM (or any machine with kubectl access).
    # `az connectedk8s enable-features` uses the Azure CLI which:
    #   1. Registers the feature with Azure ARM
    #   2. Runs `helm upgrade azure-arc` to update the release in the cluster
    # Running from Windows without local kubectl access only does step 1 and
    # leaves the cluster helm chart unconfigured.
    # Ref: Known issue — Az.ConnectedKubernetes custom-locations Helm gap
    # =======================================================================
    Write-Step "Step 4/12: Enabling custom-locations + cluster-connect (CLI updates ARM + Helm)"

    # Resolve OID on Windows — just an Azure AD read, no VM access needed.
    $customLocationsAppId = 'bc313c14-388c-4e7d-a58e-70017303ee3b'
    $customLocationsOid   = $null
    if (-not $DryRun) {
        $customLocationsOid = az ad sp show --id $customLocationsAppId --query id -o tsv 2>$null
        if (-not $customLocationsOid) {
            Write-Warn "Could not retrieve Custom Locations RP OID - will attempt without it"
            $customLocationsOid = ''
        } else {
            Write-Info "Custom Locations OID: $customLocationsOid"
        }
    } else {
        $customLocationsOid = 'DRY-RUN-OID'
    }

    $oidArg = if ($customLocationsOid) { "--custom-locations-oid `"$customLocationsOid`"" } else { '' }

    $enableFeaturesScript = @"
#!/bin/bash
set -e
echo "[CUSTOM-LOC] Logging in with VM managed identity..."
az login --identity --output none
az account set --subscription "$subscriptionId" --output none

echo "[CUSTOM-LOC] Enabling cluster-connect and custom-locations features..."
az connectedk8s enable-features \
    --name "$clusterName" \
    --resource-group "$resourceGroup" \
    --features cluster-connect custom-locations \
    $oidArg \
    --output none 2>&1 || echo "[CUSTOM-LOC] NOTE: Feature may already be enabled - continuing"

echo "[CUSTOM-LOC] Verifying Helm chart update..."
helm get values azure-arc --namespace azure-arc-release -o json 2>/dev/null \
    | jq '.systemDefaultValues.customLocations' 2>/dev/null \
    || echo "(helm verification unavailable - jq may not be installed)"

echo "[CUSTOM-LOC] Done."
"@

    Invoke-VmScript -Description "az connectedk8s enable-features (custom-locations + Helm update)" -BashScript $enableFeaturesScript

    # =======================================================================
    # STEP 5 — Enable workload identity webhook
    #
    # `az connectedk8s update --enable-workload-identity` is an Azure ARM call
    # that triggers the Arc agent to deploy the workload identity webhook
    # DaemonSet into the cluster. Safe to run from Windows.
    # Ref: Known issue — Az.ConnectedKubernetes WorkloadIdentityEnabled gap
    # =======================================================================
    Write-Step "Step 5/12: Enabling workload identity webhook (az connectedk8s update)"

    if (-not $DryRun) {
        az connectedk8s update `
            --name $clusterName `
            --resource-group $resourceGroup `
            --enable-workload-identity `
            --output none

        Write-Info "Waiting 45s for workload identity webhook pods to deploy..."
        Start-Sleep -Seconds 45
    } else {
        Write-Warn "[DryRun] Would run: az connectedk8s update --name $clusterName --enable-workload-identity"
    }
    Write-OK "Workload identity webhook deployment triggered."

    # =======================================================================
    # STEP 6 — Grant KV Secrets User to Arc cluster identity
    #
    # The Arc cluster receives a system-assigned identity when connected.
    # Its principal ID is only known after Step 2, so Bicep cannot pre-assign
    # this role. Grant it now so the Arc agent can access Key Vault secrets.
    # =======================================================================
    Write-Step "Step 6/12: Granting KV Secrets User to Arc cluster identity"

    if (-not $DryRun) {
        $arcIdentity = az connectedk8s show `
            --name $clusterName `
            --resource-group $resourceGroup `
            --query "identity.principalId" -o tsv 2>$null

        if ($arcIdentity) {
            az role assignment create `
                --role $kvSecretsUserRoleId `
                --assignee-object-id $arcIdentity `
                --assignee-principal-type ServicePrincipal `
                --scope $kvResourceId `
                --output none 2>$null
            Write-OK "Granted KV Secrets User to Arc cluster identity ($arcIdentity)"
        } else {
            Write-Warn "Could not retrieve Arc cluster identity principal ID - KV grant skipped"
            Write-Warn "Add manually: az role assignment create --role $kvSecretsUserRoleId --assignee <arcIdentity> --scope $kvResourceId"
        }
    } else {
        Write-Warn "[DryRun] Would grant KV Secrets User to Arc cluster identity"
    }

} # end -not $SkipArc

if (-not $SkipAio) {

    # =======================================================================
    # STEP 7 — az iot ops init
    # Installs the AIO Arc extensions (iot-operations, cert-manager, etc.)
    # onto the connected cluster. Pure ARM API call - no kubectl needed.
    # If the instance already exists, runs upgrade instead.
    # =======================================================================
    Write-Step "Step 7/12: Running az iot ops init"

    if (-not $DryRun) {
        $existingState = az iot ops show `
            --name $instanceName `
            --resource-group $resourceGroup `
            --query "provisioningState" -o tsv 2>$null

        if ($existingState) {
            Write-OK "AIO instance '$instanceName' already exists (state: $existingState) - running upgrade."
            az iot ops upgrade --name $instanceName --resource-group $resourceGroup -y 2>&1 | Out-Null
        } else {
            az iot ops init `
                --cluster $clusterName `
                --resource-group $resourceGroup

            Write-Info "az iot ops init complete. Waiting 60s for Arc extensions to settle..."
            Start-Sleep -Seconds 60
        }
    } else {
        Write-Warn "[DryRun] Would run: az iot ops init --cluster $clusterName --resource-group $resourceGroup"
    }
    Write-OK "az iot ops init done."

    # =======================================================================
    # STEP 8 — az iot ops create
    # Deploys the AIO instance onto the Arc-connected cluster.
    #   --sr-resource-id   : Schema Registry (required)
    #   --ns-resource-id   : Device Registry namespace (AIO v1.2+ portal asset API)
    #   --no-progress      : Suppress animated progress bar (clean logs in CI/azd)
    # =======================================================================
    Write-Step "Step 8/12: Running az iot ops create"

    if (-not $DryRun) {
        $alreadyExists = az iot ops show `
            --name $instanceName `
            --resource-group $resourceGroup `
            --query "provisioningState" -o tsv 2>$null

        if ($alreadyExists) {
            Write-OK "AIO instance '$instanceName' already exists - skipping create."
        } else {
            $srId = az resource show `
                --resource-type 'Microsoft.DeviceRegistry/schemaRegistries' `
                --resource-group $resourceGroup `
                --name $schemaRegistry `
                --query id -o tsv

            if (-not $srId) {
                Write-Error "Schema Registry '$schemaRegistry' not found. Bicep provisioning may have failed."
            }

            # Build argument list dynamically to optionally include --ns-resource-id
            $createArgs = @(
                'iot', 'ops', 'create',
                '--cluster',        $clusterName,
                '--resource-group', $resourceGroup,
                '--name',           $instanceName,
                '--sr-resource-id', $srId,
                '--no-progress'
            )

            if ($drNamespaceId) {
                $createArgs += @('--ns-resource-id', $drNamespaceId)
                Write-Info "Including --ns-resource-id for AIO v1.2+ asset namespace"
            } else {
                Write-Warn "--ns-resource-id not available (AIO_DEVICE_REGISTRY_NAMESPACE_ID not set) - portal-created assets may use old API"
            }

            Write-Info "Deploying AIO instance '$instanceName' (this may take 5-10 minutes)..."
            az @createArgs

            if ($LASTEXITCODE -ne 0) {
                Write-Error "az iot ops create failed. Check the Azure portal for Arc extension deployment status."
            }
        }
    } else {
        Write-Warn "[DryRun] Would run: az iot ops create --cluster $clusterName --name $instanceName --sr-resource-id <id> --ns-resource-id <id> --no-progress"
    }
    Write-OK "AIO instance ready."

    # =======================================================================
    # STEP 9 — Enable AIO secret sync
    #
    # IMPORTANT CLI SIGNATURE: use --name <aio-instance-name>, NOT --cluster.
    # The managed identity used here is the user-assigned identity provisioned
    # by Bicep (managedIdentity.bicep). Its KV Secrets User role was assigned
    # in Bicep (roleAssignments.bicep) — no additional role grant needed here.
    # =======================================================================
    Write-Step "Step 9/12: Enabling AIO secret sync"

    if (-not $DryRun) {
        az iot ops secretsync enable `
            --name $instanceName `
            --resource-group $resourceGroup `
            --mi-user-assigned $miResourceId `
            --kv-resource-id $kvResourceId `
            --output none 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warn "secretsync enable returned non-zero — may already be enabled. Continuing."
        } else {
            Write-OK "Secret sync enabled."
        }
    } else {
        Write-Warn "[DryRun] Would run: az iot ops secretsync enable --name $instanceName --mi-user-assigned $miResourceId --kv-resource-id $kvResourceId"
    }

    # =======================================================================
    # STEP 10 — Grant KV Secrets User to AIO instance identity
    #
    # The AIO instance receives its own system-assigned identity after
    # `az iot ops create`. Its principal ID is only known at runtime.
    # Bicep cannot pre-assign this role.
    # =======================================================================
    Write-Step "Step 10/12: Granting KV Secrets User to AIO instance identity"

    if (-not $DryRun) {
        $aioIdentity = az iot ops show `
            --name $instanceName `
            --resource-group $resourceGroup `
            --query "identity.principalId" -o tsv 2>$null

        if ($aioIdentity) {
            az role assignment create `
                --role $kvSecretsUserRoleId `
                --assignee-object-id $aioIdentity `
                --assignee-principal-type ServicePrincipal `
                --scope $kvResourceId `
                --output none 2>$null
            Write-OK "Granted KV Secrets User to AIO instance identity ($aioIdentity)"
        } else {
            Write-Warn "Could not retrieve AIO instance identity - KV grant skipped"
            Write-Warn "Add manually: az role assignment create --role $kvSecretsUserRoleId --assignee <aioIdentity> --scope $kvResourceId"
        }
    } else {
        Write-Warn "[DryRun] Would grant KV Secrets User to AIO instance identity"
    }

    # =======================================================================
    # STEP 11 — Seed placeholder secrets in Key Vault
    # Replace these with real values before deploying Fabric RTI dataflows.
    # See: issues/fabric_entra_id_gap.md and SASL_AUTH_AND_KV_Review.md
    # =======================================================================
    Write-Step "Step 11/12: Seeding Key Vault placeholder secrets"

    $placeholders = [ordered]@{
        'fabric-connection-string' = 'PLACEHOLDER-replace-with-actual-Fabric-Event-Stream-SAS-connection-string'
    }

    foreach ($secretName in $placeholders.Keys) {
        if (-not $DryRun) {
            $existingVal = az keyvault secret show `
                --vault-name $kvName `
                --name $secretName `
                --query value -o tsv 2>$null
            if ($existingVal) {
                Write-Info "Secret '$secretName' already exists - skipping."
            } else {
                az keyvault secret set `
                    --vault-name $kvName `
                    --name $secretName `
                    --value $placeholders[$secretName] `
                    --output none | Out-Null
                Write-OK "Created placeholder secret: $secretName"
            }
        } else {
            Write-Warn "[DryRun] Would create placeholder secret: $secretName"
        }
    }

    # =======================================================================
    # STEP 12 — Optional edge module deployment
    # =======================================================================
    Write-Step "Step 12/12: Edge module deployment"

    $deployFlags = [ordered]@{
        'edgemqttsim'   = ($azdEnv['DEPLOY_MODULE_EDGEMQTTSIM']  -eq 'true')
        'sputnik'       = ($azdEnv['DEPLOY_MODULE_SPUTNIK']       -eq 'true')
        'hello-flask'   = ($azdEnv['DEPLOY_MODULE_HELLO_FLASK']   -eq 'true')
        'demohistorian' = ($azdEnv['DEPLOY_MODULE_DEMOHISTORIAN'] -eq 'true')
    }

    $enabledModules = $deployFlags.Keys | Where-Object { $deployFlags[$_] }

    if ($enabledModules -and -not $SkipModules) {
        Write-Info "Deploying modules: $($enabledModules -join ', ')..."
        & "$PSScriptRoot\deploy-modules.ps1" -DeployFlags $deployFlags -AcrServer $acrServer
    } else {
        Write-Info "No modules selected for deployment."
        Write-Info "To deploy: azd env set DEPLOY_MODULE_EDGEMQTTSIM true  (then azd up)"
        Write-Info "Or standalone: .\azd-deploy\scripts\deploy-modules.ps1 -Module edgemqttsim"
    }

} # end -not $SkipAio

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "===      Post-Provision Complete            ===" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Cluster  : $clusterName"
Write-Host "  Instance : $instanceName"
Write-Host "  Key Vault: $kvUri"
Write-Host ""
Write-Host "Connect kubectl to the cluster:" -ForegroundColor Cyan
Write-Host "  az connectedk8s proxy --name $clusterName --resource-group $resourceGroup"
Write-Host ""
Write-Host "Verify AIO health:" -ForegroundColor Cyan
Write-Host "  kubectl get pods -n azure-iot-operations"
Write-Host ""
Write-Host "Replace the fabric-connection-string KV secret when you set up Fabric RTI:" -ForegroundColor Cyan
Write-Host "  az keyvault secret set --vault-name $kvName --name fabric-connection-string --value `"<your-sas-string>`""
Write-Host ""
