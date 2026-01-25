# Bug Report: Fabric Real-Time Intelligence Endpoint Deployment Failure

**Date**: January 24, 2026  
**Environment**: Azure IoT Operations on Arc-connected K3s cluster  
**Severity**: High - Blocks Fabric RTI integration through Azure portal

## Issue Summary

Deploying a Fabric Real-Time Intelligence endpoint through the Azure IoT Operations portal results in a **Failed** provisioning state. The endpoint cannot establish connectivity to Fabric Event Streams due to missing Kubernetes secret synchronization from Azure Key Vault.

## Environment Details

- **Cluster Type**: Arc-connected Kubernetes (K3s v1.34.3+k3s1)
- **AIO Version**: 1.3.x
- **Cluster Name**: iot-ops-cluster
- **Resource Group**: IoT-Operations
- **Key Vault**: iot-opps-keys
- **Management**: Windows 10/11 via `az connectedk8s proxy`

## Root Causes Identified

### 1. Secret Sync Failure (Primary Issue)

**Problem**: The SecretProviderClass configured by External-Configurator.ps1 was set to use VM managed identity authentication, which does NOT work on Arc-connected clusters.

**Configuration Error**:
```yaml
# What was created (WRONG for Arc clusters):
spec:
  provider: azure
  parameters:
    useVMManagedIdentity: "true"  # Only works on Azure VMs
    keyvaultName: "iot-opps-keys"
```

**Why it failed**:
- Arc-connected clusters require **workload identity** with federated credentials, NOT VM managed identity
- Azure Key Vault CSI driver attempted to use VM managed identity → authentication failed
- Error: `failed to parse workload identity tokens, error: service account tokens not found`
- Result: Secret `fabric-connection-string` never synced from Key Vault to cluster

### 2. Missing Workload Identity Infrastructure

**Problem**: Azure Workload Identity webhook was not installed in the cluster.

**Why this matters**:
- Workload identity requires the webhook to inject OIDC tokens into pod service accounts
- Without the webhook, CSI driver cannot authenticate to Key Vault using federated credentials
- The webhook installation (`azure-workload-identity`) is a prerequisite that wasn't documented or automated

**Attempted Fix (Failed)**:
- Installed `azure-workload-identity` webhook via kubectl
- Webhook pods entered crash loop due to certificate generation issues
- Even if working, this approach requires additional service account annotations and federated credential configuration

### 3. Incorrect Endpoint Authentication Configuration

**Problem**: When fabric-endpoint was created (either through portal or initial scripts), it used the wrong authentication method.

**What was deployed**:
```yaml
spec:
  kafkaSettings:
    authentication:
      method: SystemAssignedManagedIdentity  # WRONG
      systemAssignedManagedIdentitySettings: {}
```

**What should be deployed**:
```yaml
spec:
  kafkaSettings:
    authentication:
      method: Sasl
      saslSettings:
        saslType: Plain
        secretRef: fabric-connection-string
```

**Why it failed**:
- Fabric Event Hubs (backing Event Streams) requires SASL/Plain authentication with connection string
- SystemAssignedManagedIdentity is not supported for Fabric Event Hubs Kafka endpoint
- The portal or deployment process selected the wrong authentication method

### 4. Secret Format Requirements

**Problem**: Even when manually created, the secret must have specific keys.

**Required format**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: fabric-connection-string
  namespace: azure-iot-operations
type: Opaque
data:
  username: JENvbm5lY3Rpb25TdHJpbmc=  # base64 of "$ConnectionString"
  password: <base64 of actual connection string>
```

**Common mistakes**:
- Creating secret with `connectionString` key → CSI driver expects `username` and `password`
- Missing the literal `$ConnectionString` as username → Kafka SASL authentication fails

### 5. Topic/EntityPath Mismatch

**Problem**: Fabric Event Stream connection strings include a specific `EntityPath` that must be used as the Kafka topic.

**Connection string format**:
```
Endpoint=sb://server.servicebus.windows.net/;SharedAccessKeyName=key_xxx;SharedAccessKey=xxx;EntityPath=es_e526de3f-6433-4a35-8f07-521f30abe1c5
```

**Issue**:
- Custom topic names (e.g., `historian/health`) don't work
- Must extract and use the `EntityPath` value from connection string
- Error if wrong topic: `UnknownTopicOrPartition (Broker: Unknown topic or partition)`

## Workaround Implemented

### Step 1: Manual Secret Creation
Since CSI driver secret sync doesn't work on Arc clusters without extensive workload identity setup:

```powershell
# Fetch secret from Key Vault
$connString = az keyvault secret show --vault-name iot-opps-keys --name fabric-connection-string --query value -o tsv

# Create Kubernetes secret with correct format
kubectl delete secret fabric-connection-string -n azure-iot-operations
kubectl create secret generic fabric-connection-string -n azure-iot-operations `
  --from-literal=username='$ConnectionString' `
  --from-literal=password=$connString
```

### Step 2: Deploy Endpoint with Correct Configuration
```powershell
# Delete failed Azure-managed resource
az iot ops dataflow endpoint delete --name fabric-endpoint --instance iot-ops-cluster-aio --resource-group IoT-Operations --yes

# Create endpoint with SASL authentication
$endpoint = @'
apiVersion: connectivity.iotoperations.azure.com/v1
kind: DataflowEndpoint
metadata:
  name: fabric-endpoint
  namespace: azure-iot-operations
spec:
  endpointType: Kafka
  kafkaSettings:
    host: "esehmtcyb1tve3fs2la76yiy.servicebus.windows.net:9093"
    tls:
      mode: Enabled
    authentication:
      method: Sasl
      saslSettings:
        saslType: Plain
        secretRef: fabric-connection-string
    consumerGroupId: iot-operations-consumer
    compression: None
    copyMqttProperties: Enabled
    cloudEventAttributes: Propagate
'@
$endpoint | kubectl apply -f -
```

### Step 3: Extract and Use Correct Topic Name
```powershell
# Parse EntityPath from connection string
$connString = az keyvault secret show --vault-name iot-opps-keys --name fabric-connection-string --query value -o tsv
if ($connString -match 'EntityPath=([^;]+)') {
    $topicName = $matches[1]
    Write-Host "Topic: $topicName"  # es_e526de3f-6433-4a35-8f07-521f30abe1c5
}

# Create dataflow with correct topic
kubectl create -f - <<EOF
apiVersion: connectivity.iotoperations.azure.com/v1
kind: Dataflow
metadata:
  name: demohistoran-health-to-fabric
  namespace: azure-iot-operations
spec:
  profileRef: default
  mode: Enabled
  operations:
  - operationType: Source
    sourceSettings:
      endpointRef: default
      dataSources:
      - historian/health
      assetRef: iot-operations-ns/demohistorian-asset
  - operationType: BuiltInTransformation
    builtInTransformationSettings:
      map:
      - inputs: ['*']
        output: '*'
  - operationType: Destination
    destinationSettings:
      endpointRef: fabric-endpoint
      dataDestination: $topicName
EOF
```

## Impact

**What works**:
- ✅ Data successfully flows from AIO to Fabric Event Stream (123 msg/min observed)
- ✅ Fabric Eventhouse receives data
- ✅ Dataflow status shows healthy operation

**What doesn't work**:
- ❌ Azure portal shows fabric-endpoint as "Failed" (no ARM resource linkage)
- ❌ Secret sync from Key Vault on Arc clusters
- ❌ Portal-based Fabric endpoint deployment
- ❌ ARM template deployments that depend on secret sync

## Why We "Went Outside of AIO"

**Definition**: "Going outside" means managing Kubernetes resources directly via kubectl instead of through Azure Resource Manager (ARM) / Azure portal.

**Why this was necessary**:
1. **Secret Sync Broken**: The CSI driver with Key Vault integration doesn't work for Arc clusters with the current configuration
2. **Portal Deployment Failed**: Azure portal created the endpoint with wrong authentication method
3. **ARM Doesn't See It**: Resources created via kubectl don't have Azure management annotations, so portal can't track them
4. **No Alternative**: The "proper" path (workload identity setup) requires:
   - Installing Azure Workload Identity webhook
   - Configuring service account with federated credentials
   - Annotating service accounts with client ID and tenant ID
   - Debugging webhook certificate issues
   - This is complex and wasn't documented in AIO setup

## Recommendations for Microsoft

### 1. Fix External-Configurator.ps1
Update the script to properly detect Arc clusters and configure workload identity instead of VM managed identity:

```powershell
# Detect cluster type
$clusterType = az connectedk8s show --name $ClusterName --resource-group $ResourceGroup --query "kind" -o tsv

if ($clusterType -eq "ProvisionedCluster") {
    # Arc cluster: use workload identity
    $spcConfig = @"
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
    clientID: "$managedIdentityClientId"
    tenantId: "$tenantId"
    keyvaultName: "$KeyVaultName"
"@
    
    # Install workload identity if not present
    # Configure service account annotations
    # Create federated credential
}
```

### 2. Automate Workload Identity Setup
Add to External-Configurator.ps1:
- Install azure-workload-identity webhook
- Create service account with proper annotations
- Set up federated credentials automatically
- Validate webhook is running before proceeding

### 3. Fix Portal Fabric Endpoint Creation
The portal should:
- Detect Fabric Event Stream endpoints
- Automatically select SASL authentication (not SystemAssignedManagedIdentity)
- Extract EntityPath from connection string
- Pre-populate topic name in dataflow creation

### 4. Documentation Updates
- Document Arc cluster requirements for secret sync
- Provide clear instructions for manual secret creation as fallback
- Explain EntityPath requirement for Fabric Event Streams
- Add troubleshooting guide for "UnknownTopicOrPartition" errors

### 5. Better Error Messages
Instead of generic "Failed" status, show:
- "Secret 'fabric-connection-string' not found in cluster"
- "Workload identity not configured for Arc cluster"
- "Topic 'xxx' does not exist - check EntityPath in connection string"

## Testing Commands

**Verify secret exists**:
```bash
kubectl get secret fabric-connection-string -n azure-iot-operations
```

**Check dataflow logs**:
```bash
kubectl logs -n azure-iot-operations aio-dataflow-default-0 --tail=50
```

**Verify data flowing**:
```bash
# Should show msg/min rate, no "Failed to deliver" errors
kubectl logs -n azure-iot-operations aio-dataflow-default-0 --since=1m | grep -E "msg/min|Failed"
```

## Related Issues

- CSI Secret Store provider with Arc clusters
- Azure Workload Identity integration
- Fabric Event Stream topic/EntityPath confusion
- Portal-managed vs kubectl-managed resource discrepancies

## Attachments

- External-Configurator.ps1 (modified version with Arc detection)
- Deploy-FabricEndpoint.ps1 (uses kubectl, not ARM)
- fabric-endpoint.yaml (SASL configuration)
- Dataflow manifest with EntityPath topic name
