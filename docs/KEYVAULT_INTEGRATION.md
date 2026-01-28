# Azure Key Vault Integration for Azure IoT Operations

## Overview

The `External-Configurator.ps1` script now automatically sets up Azure Key Vault integration for Azure IoT Operations, enabling secure secret management for dataflows and Fabric Real-Time Intelligence connections.

## What Gets Created

When you run `External-Configurator.ps1`, it now:

1. **Creates an Azure Key Vault**
   - Globally unique name: `aio-<cluster-name>-<random-suffix>`
   - RBAC authorization enabled
   - Deployment and template deployment enabled

2. **Grants Key Vault Permissions**
   - Current user: `Key Vault Administrator` (for setup)
   - Arc cluster managed identity: `Key Vault Secrets User`
   - AIO instance managed identity: `Key Vault Secrets User`
   - All other managed identities in resource group: `Key Vault Secrets User`

3. **Creates SecretProviderClass on Kubernetes**
   - Name: `aio-akv-sp`
   - Namespace: `azure-iot-operations`
   - Uses VM managed identity for authentication
   - Ready to reference secrets from Key Vault

## Prerequisites

Before Key Vault integration works, you MUST have:

1. **CSI Secret Store Driver installed on K3s cluster**
   - Run the updated `linux_installer.sh` on your edge device
   - Or install manually (see `CSI_SECRET_STORE_SETUP.md`)

2. **Azure IoT Operations deployed**
   - The script deploys AIO first, then sets up Key Vault
   - Managed identities must be created before permissions can be granted

## Usage

### Basic Usage (Automatic Key Vault Setup)

```powershell
# Runs full deployment including Key Vault integration
.\External-Configurator.ps1 -ClusterInfo edge_configs\cluster_info.json -ConfigFile edge_configs\linux_aio_config.json
```

### Skip Key Vault Setup

```powershell
# Skip Key Vault if you don't need secret management
.\External-Configurator.ps1 -ClusterInfo edge_configs\cluster_info.json -SkipKeyVault
```

### Custom Key Vault Name

Add to your `linux_aio_config.json`:

```json
{
  "azure": {
    "subscription_id": "...",
    "resource_group": "...",
    "location": "...",
    "cluster_name": "...",
    "namespace_name": "...",
    "key_vault_name": "my-custom-keyvault-name"
  }
}
```

## Adding Secrets to Key Vault

### During Script Execution (Interactive)

The script will prompt:

```
Would you like to add sample secrets to the Key Vault? (y/N)
```

If you say `y`, it will ask for:
- Fabric Real-Time Intelligence connection string

### After Script Execution

Add secrets using Azure CLI:

```powershell
# Add a Fabric connection string
az keyvault secret set `
  --vault-name <key-vault-name> `
  --name "fabric-connection-string" `
  --value "Endpoint=sb://..."

# Add any custom secret
az keyvault secret set `
  --vault-name <key-vault-name> `
  --name "my-secret-name" `
  --value "my-secret-value"
```

### Using Azure Portal

1. Navigate to your Key Vault in Azure portal
2. Go to **Secrets** blade
3. Click **+ Generate/Import**
4. Enter secret name and value
5. Click **Create**

## Using Secrets in AIO Dataflows

### In ARM Templates

```json
{
  "type": "Microsoft.IoTOperations/instances/dataflowEndpoints",
  "properties": {
    "endpointType": "FabricOneLake",
    "fabricOneLakeSettings": {
      "authentication": {
        "method": "ServiceAccountToken"
      },
      "host": "https://api.fabric.microsoft.com",
      "workspaceId": "<workspace-id>",
      "connectionStringSecretRef": "aio-akv-sp/fabric-connection-string"
    }
  }
}
```

### In YAML Configurations

```yaml
apiVersion: connectivity.iotoperations.azure.com/v1beta1
kind: DataflowEndpoint
metadata:
  name: fabric-endpoint
  namespace: azure-iot-operations
spec:
  endpointType: FabricOneLake
  fabricOneLakeSettings:
    authentication:
      method: ServiceAccountToken
    host: https://api.fabric.microsoft.com
    workspaceId: <workspace-id>
    connectionStringSecretRef: aio-akv-sp/fabric-connection-string
```

### Secret Reference Format

Always use this format: `aio-akv-sp/<secret-name>`

Examples:
- `aio-akv-sp/fabric-connection-string`
- `aio-akv-sp/my-custom-secret`
- `aio-akv-sp/api-key`

## Architecture

```
Azure Key Vault (aio-<cluster>-xxxxx)
  │
  ├─ Secrets
  │   ├─ fabric-connection-string
  │   ├─ my-custom-secret
  │   └─ ...
  │
  └─ RBAC Permissions
      ├─ Current User (Administrator)
      ├─ Arc Cluster Identity (Secrets User)
      ├─ AIO Instance Identity (Secrets User)
      └─ Other Managed Identities (Secrets User)

Kubernetes Cluster
  │
  └─ azure-iot-operations namespace
      │
      ├─ SecretProviderClass: aio-akv-sp
      │   └─ References: Key Vault (aio-<cluster>-xxxxx)
      │
      └─ DataflowEndpoint Pods
          └─ Mount secrets via CSI driver
```

## Verification

### Check Key Vault Exists

```powershell
az keyvault show --name <key-vault-name> --resource-group <rg-name>
```

### Check SecretProviderClass

```bash
kubectl get secretproviderclass aio-akv-sp -n azure-iot-operations
```

### Check Permissions

```powershell
az role assignment list `
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg-name>/providers/Microsoft.KeyVault/vaults/<kv-name>"
```

### Test Secret Access

```powershell
# List secrets (requires appropriate permissions)
az keyvault secret list --vault-name <key-vault-name>

# Get a specific secret
az keyvault secret show --vault-name <key-vault-name> --name fabric-connection-string
```

## Troubleshooting

### "Failed to fetch the secret provider" Error

**Causes:**
1. CSI Secret Store driver not installed on cluster
2. SecretProviderClass not created
3. Managed identity lacks Key Vault permissions

**Solutions:**

1. **Check CSI driver:**
   ```bash
   kubectl get csidriver secrets-store.csi.k8s.io
   kubectl get pods -n kube-system | grep secrets-store
   ```

2. **Check SecretProviderClass:**
   ```bash
   kubectl get secretproviderclass -n azure-iot-operations
   kubectl describe secretproviderclass aio-akv-sp -n azure-iot-operations
   ```

3. **Check permissions:**
   ```powershell
   # Run diagnostic script
   cd Fabric_setup
   .\Check-SecretManagement.ps1 -ResourceGroup <rg-name> -ClusterName <cluster-name>
   ```

### Key Vault Not Created

**If script skipped Key Vault creation:**

1. Check if `-SkipKeyVault` flag was used
2. Verify CSI Secret Store is installed (required prerequisite)
3. Check logs: `external_configurator_*.log`

**Manual creation:**

```powershell
# Create Key Vault
az keyvault create `
  --name <unique-name> `
  --resource-group <rg-name> `
  --location <location> `
  --enable-rbac-authorization true

# Grant permissions (get principal IDs from Azure portal or CLI)
az role assignment create `
  --role "Key Vault Secrets User" `
  --assignee <managed-identity-principal-id> `
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg-name>/providers/Microsoft.KeyVault/vaults/<kv-name>"
```

### Secret Not Found in Dataflow

**Check secret exists:**
```powershell
az keyvault secret show --vault-name <kv-name> --name <secret-name>
```

**Check reference format:**
- Must be: `aio-akv-sp/<secret-name>`
- NOT: `<kv-name>/<secret-name>`

**Check SecretProviderClass configuration:**
```bash
kubectl get secretproviderclass aio-akv-sp -n azure-iot-operations -o yaml
```

### Permission Denied Errors

**Grant additional permissions:**

```powershell
# Get the principal ID of the managed identity having issues
$principalId = "<principal-id-from-error>"

# Grant Key Vault Secrets User role
az role assignment create `
  --role "Key Vault Secrets User" `
  --assignee $principalId `
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg-name>/providers/Microsoft.KeyVault/vaults/<kv-name>"
```

## Best Practices

1. **Use Unique Names**: Let the script generate unique Key Vault names to avoid conflicts
2. **Store All Secrets**: Put connection strings, API keys, tokens in Key Vault (never in YAML)
3. **Use RBAC**: The script uses RBAC authorization (not access policies) for better security
4. **Rotate Secrets**: Update secrets in Key Vault; pods will automatically get new values
5. **Monitor Access**: Use Azure Monitor to track Key Vault access and detect anomalies
6. **Least Privilege**: Only grant "Secrets User" role (not "Administrator") to service identities

## Integration with Fabric RTI

For Fabric Real-Time Intelligence dataflows:

1. **Get Fabric connection string** from Event Stream (see `Fabric_setup/fabric-realtime-intelligence-setup.md`)
2. **Store in Key Vault:**
   ```powershell
   az keyvault secret set `
     --vault-name <kv-name> `
     --name "fabric-connection-string" `
     --value "Endpoint=sb://..."
   ```
3. **Reference in dataflow endpoint:**
   ```yaml
   connectionStringSecretRef: aio-akv-sp/fabric-connection-string
   ```

## Related Documentation

- [CSI_SECRET_STORE_SETUP.md](CSI_SECRET_STORE_SETUP.md) - CSI driver installation
- [Fabric_setup/fabric-realtime-intelligence-setup.md](../Fabric_setup/fabric-realtime-intelligence-setup.md) - Fabric integration
- [External-Configurator-README.md](External-Configurator-README.md) - Script usage
- [Check-SecretManagement.ps1](../Fabric_setup/Check-SecretManagement.ps1) - Diagnostic tool

## What Changed in External-Configurator.ps1

### New Features (v1.0.0)

1. **Automatic Key Vault creation** (Phase 6.5 in deployment)
2. **Managed identity permissions** automatically granted
3. **SecretProviderClass** automatically created on cluster
4. **Interactive secret addition** during script execution
5. **New `-SkipKeyVault` parameter** to disable Key Vault setup
6. **Key Vault info** in deployment summary

### Configuration File Support

Add to `linux_aio_config.json`:

```json
{
  "azure": {
    "key_vault_name": "my-custom-keyvault"
  }
}
```

If not specified, auto-generates: `aio-<cluster-name>-<random-suffix>`

## Summary

The External-Configurator now provides **complete end-to-end Key Vault integration**, enabling secure secret management for Azure IoT Operations dataflows without manual configuration. Simply run the script, and Key Vault will be ready for use with Fabric RTI and other secure endpoints.
