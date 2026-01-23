# Fix "Secret Management is Not Configured" Error

This guide focuses specifically on resolving the **"secret management is not configured"** error when deploying Fabric RTI dataflow endpoints in Azure IoT Operations.

## What This Error Means

The error indicates that the infrastructure for secret management is not properly set up. **You do NOT need secrets in Key Vault to fix this error** - the error is about infrastructure configuration, not the presence of secrets.

## Prerequisites

- kubectl access to the cluster (via Arc proxy or direct)
- Azure CLI installed

---

## Step 1: Verify OIDC Issuer and Workload Identity

**Via Azure CLI (PowerShell):**
```powershell
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations --query "{oidc:oidcIssuerProfile.enabled,workloadId:securityProfile.workloadIdentity.enabled}" -o table
```

**Or check each separately:**
```powershell
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations --query "oidcIssuerProfile.enabled" -o tsv
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations --query "securityProfile.workloadIdentity.enabled" -o tsv
```

✅ **Expected output:** Both should return `True`

**If not enabled:**
```powershell
az connectedk8s update -n iot-ops-cluster -g IoT-Operations --enable-oidc-issuer --enable-workload-identity
```

---

## Step 2: Verify SecretProviderClass Exists

**This is the most common cause of the error.**

### 2.1 Connect to Cluster
```powershell
# Via Arc proxy (if remote)
az connectedk8s proxy --name iot-ops-cluster --resource-group IoT-Operations
# Wait 30 seconds, then in a new terminal:
kubectl config use-context iot-ops-cluster
```

### 2.2 Check if SecretProviderClass Exists
```powershell
kubectl get secretproviderclass -n azure-iot-operations
```

✅ **Expected output:**
```
NAME         AGE
aio-akv-sp   <time>
```

❌ **If you see: "No resources found"** - This is your problem!

### 2.3 Create the SecretProviderClass

**If missing, recreate it:**
```powershell
cd linux_build
.\External-Configurator.ps1 -ClusterInfo edge_configs\cluster_info.json -ConfigFile edge_configs\linux_aio_config.json
```

Or delete existing one manually if you need to recreate:
```powershell
kubectl delete secretproviderclass aio-akv-sp -n azure-iot-operations 2>$null
```

Then verify it was created in the External-Configurator output.

---

## Step 3: Verify Secret Sync is Enabled

**Check if secret sync managed identity exists:**
```powershell
az identity show --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --query "{name:name,principalId:principalId}" -o table
```

✅ **Expected:** Should show the managed identity with a principal ID

**Verify the identity has Key Vault permissions:**
```powershell
# Get the principal ID
$PRINCIPAL_ID = az identity show --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --query principalId -o tsv 2>$null

# Check role assignments (if identity exists)
if ($PRINCIPAL_ID) {
    az role assignment list --assignee $PRINCIPAL_ID --scope "/subscriptions/5c043aac-3d88-43d5-aec8-cd02ee6c914a/resourceGroups/IoT-Operations/providers/Microsoft.KeyVault/vaults/iot-opps-keys" --query "[].roleDefinitionName" -o tsv
}
```

✅ **Expected:** Should show `Key Vault Secrets User`

❌ **If secret sync managed identity is missing, run the External-Configurator:**
```powershell
cd linux_build
.\External-Configurator.ps1 -ClusterInfo edge_configs\cluster_info.json -ConfigFile edge_configs\linux_aio_config.json
```

The configurator will:
1. Create the `iot-ops-cluster-secretsync-mi` managed identity
2. Grant it Key Vault permissions
3. Enable secret sync on the AIO instance

**Or enable manually:**
```powershell
# Check if managed identity exists
$MI_ID = az identity show --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --query id -o tsv 2>$null

# If identity doesn't exist, create it
if (-not $MI_ID) {
    Write-Host "Creating managed identity for secret sync..."
    az identity create --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --location westus3
    Start-Sleep -Seconds 10  # Wait for creation
    $MI_ID = az identity show --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --query id -o tsv
}

# Get Key Vault resource ID
$KV_ID = "/subscriptions/5c043aac-3d88-43d5-aec8-cd02ee6c914a/resourceGroups/IoT-Operations/providers/Microsoft.KeyVault/vaults/iot-opps-keys"

# Grant Key Vault permissions to the managed identity
$MI_PRINCIPAL = az identity show --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --query principalId -o tsv
az role assignment create --role "Key Vault Secrets User" --assignee $MI_PRINCIPAL --scope $KV_ID

# Enable secret sync (this is what actually enables it)
az iot ops secretsync enable --instance iot-ops-cluster-aio -g IoT-Operations --mi-user-assigned $MI_ID --kv-resource-id $KV_ID
```

---

## Step 4: Fix Dataflow Endpoint Secret Reference

**The most critical step - incorrect format causes the error.**

⚠️ **Important:** This error only occurs with **Fabric/Event Hub/external endpoints** that use secrets, NOT with internal MQTT broker endpoints.

### 4.1 Check Your Fabric/Event Hub Endpoint

**Note:** These kubectl commands run through your Arc proxy context.

```powershell
# List all dataflow endpoints
kubectl get dataflowendpoint -n azure-iot-operations
```

**Expected results:**
- You'll see `default` (the MQTT broker endpoint) - this is normal and correct
- If you ONLY see `default`, you **haven't created a Fabric endpoint yet**
- The error won't appear until you try to CREATE a Fabric endpoint

```powershell
# Check if you have any Fabric endpoints (not the MQTT broker one)
kubectl get dataflowendpoint -n azure-iot-operations -o json | Select-String "FabricOneLake"
```

❌ **If empty:** You haven't created a Fabric endpoint yet. The error will appear when you create one with incorrect secret format.

✅ **If you see a Fabric endpoint, check its configuration:**
```powershell
kubectl describe dataflowendpoint <your-fabric-endpoint-name> -n azure-iot-operations
```

**What you're looking for:**
- ❌ **Skip** endpoints with `Endpoint Type: Mqtt` and `Method: ServiceAccountToken` (this is your "default" broker endpoint - it's correct)
- ✅ **Check** endpoints with `Endpoint Type: FabricOneLake` or `Kafka` (external endpoints that need secrets)

### 4.2 Verify Secret Reference Format

When you create a **Fabric RTI or Event Hub endpoint**, the authentication section must look like this:

✅ **CORRECT format:**
```yaml
authentication:
  method: SystemAssignedManagedIdentity
  systemAssignedManagedIdentitySettings:
    secretRef: aio-akv-sp/my-secret-name
```

❌ **WRONG - Missing prefix (causes the error):**
```yaml
secretRef: my-secret-name
```

❌ **WRONG - Wrong prefix:**
```yaml
secretRef: keyvault/my-secret-name
```

### 4.3 Example: Creating a Fabric Endpoint with Secrets

```yaml
apiVersion: connectivity.iotoperations.azure.com/v1beta1
kind: DataflowEndpoint
metadata:
  name: fabric-endpoint
  namespace: azure-iot-operations
spec:
  endpointType: FabricOneLake
  fabricOneLakeSettings:
    host: "https://msit-onelake.dfs.fabric.microsoft.com"
    authentication:
      method: SystemAssignedManagedIdentity
      systemAssignedManagedIdentitySettings:
        secretRef: aio-akv-sp/fabric-connection-string  # Must use this format!
```

### 4.3 The Secret Reference Format Explained

- `aio-akv-sp` = The SecretProviderClass name (from Step 2)
- `/` = Separator (required)
- `my-secret-name` = Your secret name in Key Vault (can be anything)

**The secret name can be anything** - it does NOT have to be `fabric-connection-string`. Examples:
- `aio-akv-sp/fabric-conn-str`
- `aio-akv-sp/eventhub-connection`
- `aio-akv-sp/my-custom-secret`

Just make sure the secret with that name exists in Key Vault when you deploy.

---

## Quick Validation Checklist

Run these commands to check everything:

```powershell
# 1. OIDC/Workload Identity
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations --query "oidcIssuerProfile.enabled" -o tsv
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations --query "securityProfile.workloadIdentity.enabled" -o tsv

# 2. SecretProviderClass exists
kubectl get secretproviderclass aio-akv-sp -n azure-iot-operations

# 3. Secret Sync managed identity exists
az identity show --name iot-ops-cluster-secretsync-mi --resource-group IoT-Operations --query name -o tsv

# 4. Check your dataflow endpoint
kubectl describe dataflowendpoint <your-endpoint-name> -n azure-iot-operations | Select-String "secretRef"
```

✅ **All four must return success for secret management to work.**

---

## Troubleshooting

### Still Getting the Error?

1. **Delete and recreate the dataflow endpoint** with correct secret reference format
2. **Restart the dataflow operator:**
   ```powershell
   kubectl rollout restart deployment -n azure-iot-operations -l app=aio-dataflow-operator
   ```
3. **Check dataflow operator logs:**
   ```powershell
   kubectl logs -n azure-iot-operations -l app=aio-dataflow-operator --tail=50
   ```

### Common Mistakes

| Issue | Symptom | Fix |
|-------|---------|-----|
| Missing SecretProviderClass | "secret management is not configured" | Run External-Configurator.ps1 |
| Wrong secret reference | "secret management is not configured" | Use format: `aio-akv-sp/<secret-name>` |
| OIDC not enabled | "oidc issuer not enabled" | Run: `az connectedk8s update --enable-oidc-issuer --enable-workload-identity` |
| Secret sync disabled | Secrets not syncing | Run: `az iot ops secretsync enable` |

---

## Summary

To fix **"secret management is not configured"**:

1. ✅ Arc cluster must have OIDC issuer and workload identity enabled
2. ✅ SecretProviderClass `aio-akv-sp` must exist in `azure-iot-operations` namespace
3. ✅ Secret sync must be enabled on AIO instance  
4. ✅ Dataflow endpoint must use format: `aio-akv-sp/<secret-name>`

**You do NOT need secrets in Key Vault to fix this error.** Add secrets later when deploying dataflows.

If all four items are ✅ and you still get the error, check your dataflow endpoint YAML/JSON - the secret reference format is usually the culprit.

