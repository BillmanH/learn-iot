# CSI Secret Store Setup for Azure IoT Operations

## Overview

Azure IoT Operations requires the **CSI Secret Store driver** to enable secret management for dataflows, particularly when connecting to **Microsoft Fabric Real-Time Intelligence (RTI)**. Without this driver, you will encounter:

- ❌ No "Secret management" toggle in Azure portal
- ❌ Cannot create Fabric RTI endpoints
- ❌ Dataflows stuck in retry loops
- ❌ Secret references disabled

## What is CSI Secret Store?

The **Container Storage Interface (CSI) Secret Store driver** allows Kubernetes pods to mount secrets from external secret stores (like Azure Key Vault) as volumes. This is required for Azure IoT Operations dataflows to securely access connection strings and authentication tokens.

## Components

The installation includes two components:

1. **Secrets Store CSI Driver** - Core Kubernetes CSI driver
   - Resource: `secrets-store.csi.k8s.io`
   - Pods: `secrets-store-csi-driver-*` in `kube-system` namespace

2. **Azure Key Vault Provider** - Azure-specific provider
   - Pods: `csi-secrets-store-provider-azure-*` in `kube-system` namespace

## Installation

### Automatic Installation (Recommended)

The updated `linux_installer.sh` script now automatically installs the CSI Secret Store driver:

```bash
cd linux_build
./linux_installer.sh
```

This will:
- Install K3s
- Install CSI Secret Store driver via Helm
- Install Azure Key Vault provider via Helm
- Verify installation

### Manual Installation

If you need to install manually on an existing K3s cluster:

```bash
# Add Helm repos
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm repo update

# Install CSI Secret Store Driver
helm install csi-secrets-store-driver secrets-store-csi-driver/secrets-store-csi-driver \
    --namespace kube-system \
    --set syncSecret.enabled=true \
    --set enableSecretRotation=true

# Install Azure Key Vault Provider
helm install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
    --namespace kube-system

# Verify installation
kubectl get csidriver
kubectl get pods -n kube-system | grep secrets-store
kubectl get pods -n kube-system | grep csi-secrets-store-provider-azure
```

## Verification

### Quick Check

Run the verification script:

```bash
cd linux_build
chmod +x verify-csi-secret-store.sh
./verify-csi-secret-store.sh
```

### Manual Verification

Check that all required components are present:

```bash
# Must see: secrets-store.csi.k8s.io
kubectl get csidriver

# Must see pods in Running state
kubectl get pods -n kube-system | grep secrets-store

# Must see pods in Running state
kubectl get pods -n kube-system | grep csi-secrets-store-provider-azure
```

Expected output:
```
# kubectl get csidriver
NAME                        ATTACHREQUIRED   PODINFOONMOUNT   STORAGECAPACITY   TOKENREQUESTS   REQUIRESREPUBLISH   MODES        AGE
secrets-store.csi.k8s.io    false            true             false             <unset>         false               Ephemeral    5m

# kubectl get pods -n kube-system | grep secrets-store
secrets-store-csi-driver-abc123         3/3     Running   0          5m
secrets-store-csi-driver-def456         3/3     Running   0          5m

# kubectl get pods -n kube-system | grep csi-secrets-store-provider-azure
csi-secrets-store-provider-azure-xyz789  1/1     Running   0          5m
csi-secrets-store-provider-azure-uvw012  1/1     Running   0          5m
```

## Why This Matters for Fabric RTI

### Without CSI Secret Store

When you try to create a Fabric RTI dataflow endpoint in the Azure portal, you see:

1. **No secret management toggle** - The UI doesn't show configuration options
2. **Misleading documentation** - Links point to non-existent settings
3. **Deployment fails** - Dataflows cannot access secrets
4. **Portal shows errors** - "Secret management not configured"

### With CSI Secret Store

After installation:

1. ✅ **Secret management detected** - Azure IoT Operations recognizes the capability
2. ✅ **Key Vault integration** - Can reference secrets from Azure Key Vault
3. ✅ **Fabric RTI works** - Dataflows can securely access connection strings
4. ✅ **Portal configuration** - Full settings UI is available

## Troubleshooting

### Issue: CSI Driver not found

```bash
kubectl get csidriver
# No output or missing secrets-store.csi.k8s.io
```

**Solution:**
```bash
# Reinstall the CSI driver
helm uninstall csi-secrets-store-driver -n kube-system
helm install csi-secrets-store-driver secrets-store-csi-driver/secrets-store-csi-driver \
    --namespace kube-system \
    --set syncSecret.enabled=true \
    --set enableSecretRotation=true
```

### Issue: Pods not running

```bash
kubectl get pods -n kube-system | grep secrets-store
# Shows pods in Pending or Error state
```

**Solution:**
```bash
# Check pod logs
kubectl logs -n kube-system -l app.kubernetes.io/name=secrets-store-csi-driver

# Check events
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep secrets-store

# Check resource constraints
kubectl describe pod -n kube-system <pod-name>
```

### Issue: Azure provider missing

```bash
kubectl get pods -n kube-system | grep csi-secrets-store-provider-azure
# No output
```

**Solution:**
```bash
# Install the Azure provider
helm install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
    --namespace kube-system
```

### Issue: Already installed but not working

```bash
# Completely remove and reinstall
helm uninstall csi-secrets-store-driver -n kube-system
helm uninstall azure-csi-provider -n kube-system

# Wait for pods to terminate
kubectl get pods -n kube-system | grep secrets-store

# Reinstall (see Manual Installation section above)
```

## Azure IoT Operations Integration

After CSI Secret Store is installed, Azure IoT Operations will automatically detect the capability during deployment:

```powershell
# On Windows management machine
az iot ops init --cluster <cluster-name> --resource-group <rg-name>
az iot ops create --cluster <cluster-name> --resource-group <rg-name> --name <instance-name> ...
```

The `az iot ops init` command will detect:
- ✅ CSI driver presence
- ✅ Azure provider availability
- ✅ Cluster capability for secret management

This enables:
- Fabric RTI endpoint configuration
- Key Vault secret references in dataflows
- Secure token management

## Configuration for Fabric RTI

Once CSI Secret Store is installed and Azure IoT Operations is deployed, you can create Fabric RTI dataflows:

### In Azure Portal

1. Navigate to Azure IoT Operations instance
2. Go to **Dataflows**
3. Create new dataflow endpoint
4. Select **Microsoft Fabric Real-Time Intelligence**
5. Configure with Key Vault reference:
   - Workspace ID: `<your-fabric-workspace-id>`
   - Connection string: Reference to Azure Key Vault secret
   - Secret management: Now enabled and visible

### Via ARM Template

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
      "connectionStringSecretRef": "aio-akv-sp/<secret-name>"
    }
  }
}
```

## Best Practices

1. **Install during cluster setup** - Include CSI Secret Store in initial cluster configuration
2. **Verify before AIO deployment** - Run verification script before deploying Azure IoT Operations
3. **Monitor pod health** - Ensure CSI driver pods remain healthy
4. **Use Key Vault** - Store all sensitive dataflow configuration in Azure Key Vault
5. **Enable secret rotation** - Configure automatic secret rotation for security

## References

- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Azure Key Vault Provider](https://azure.github.io/secrets-store-csi-driver-provider-azure/)
- [Azure IoT Operations Documentation](https://learn.microsoft.com/azure/iot-operations/)
- [Microsoft Fabric Real-Time Intelligence](https://learn.microsoft.com/fabric/real-time-intelligence/)

## Related Files

- [`linux_installer.sh`](linux_installer.sh) - Automated installation script
- [`verify-csi-secret-store.sh`](verify-csi-secret-store.sh) - Verification script
- [`External-Configurator.ps1`](External-Configurator.ps1) - Azure IoT Operations deployment
