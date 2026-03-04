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
.\External-Configurator.ps1 -ClusterInfo edge_configs\cluster_info.json -ConfigFile edge_configs\aio_config.json
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
.\External-Configurator.ps1 -ClusterInfo edge_configs\cluster_info.json -ConfigFile edge_configs\aio_config.json
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

### 4.2 Getting Your Fabric Real-Time Intelligence Connection String

**Before creating a Fabric endpoint, you need connection details from Fabric:**

#### Step 1: Create a Fabric Event Stream

1. Go to [Microsoft Fabric](https://app.fabric.microsoft.com/)
2. Navigate to your workspace (or create a new Premium workspace)
3. Click **+ New** > **Real-Time Intelligence** > **Eventstream**
4. Name it (e.g., `iot-operations-stream`) and click **Create**

#### Step 2: Add Custom Endpoint Source

1. In the Event Stream editor, click **Add source** > **Custom endpoint**
2. Configure:
   - **Source name**: `iot-operations-data` (or any name)
   - Click **Add**
3. Click **Publish** in the Event Stream editor
4. Click on the custom endpoint you just created

#### Step 3: Get Connection Details

1. Select **Protocol**: **Kafka**
2. Select **Authentication**: **Microsoft Entra ID** (Managed Identity)
3. Copy these values:
   - **Bootstrap server**: (e.g., `<namespace>.servicebus.windows.net:9093`)
   - **Topic name**: `es_<guid>` (e.g., `es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb`)

No credentials to copy — authentication is handled automatically via the AIO managed identity.

#### Step 4: Create the Endpoint in the Azure Portal

Navigate to your AIO instance → **Dataflow endpoints** → **+ Create endpoint**:
- Type: **Kafka**
- Bootstrap server: from step 3
- Authentication: **System-assigned managed identity**

No Key Vault secrets or `kubectl` commands needed.

**Now you're ready to create the Dataflow!**

```bash
# Verify the endpoint was created successfully
kubectl get dataflowEndpoint fabric-endpoint -n azure-iot-operations
```

### 4.3 Verify Fabric Endpoint Configuration

> **Authentication method**: Fabric Event Stream custom endpoints support **Managed Identity** (`SystemAssignedManagedIdentity`). Create the endpoint in the Azure Portal to ensure the correct auth method is selected.

When checking a Fabric endpoint:

✅ **Expected endpoint YAML:**
```yaml
apiVersion: connectivity.iotoperations.azure.com/v1
kind: DataflowEndpoint
metadata:
  name: fabric-endpoint
  namespace: azure-iot-operations
spec:
  endpointType: Kafka
  kafkaSettings:
    host: "<your-bootstrap-server>:9093"
    tls:
      mode: Enabled
    authentication:
      method: SystemAssignedManagedIdentity
    copyMqttProperties: Enabled
    cloudEventAttributes: Propagate
```

❌ **WRONG - Old SAS/SASL format (no longer needed):**
```yaml
method: Sasl  # Replaced by SystemAssignedManagedIdentity
```

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

