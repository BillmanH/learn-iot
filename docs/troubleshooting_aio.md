# Troubleshooting Azure IoT Operations (AIO)

This document provides guidance for troubleshooting common Azure IoT Operations issues, with a focus on the AIO Portal, HTTP connectors, and dataset configuration errors.

## Current Issue: Dataset Configuration Parse Error

**Error Message:**
```
[demohistorian-endpoint_demohistorian-endpoint][A: demohistorian-asset][Dataset: demohistorian-health] 
Reporting dataset status error, awaiting dataset update: Some("Failed to parse dataset configuration")
```

**Portal Message:**
> Health status: An error occurred. Please check the logs for detailed information and troubleshooting.

---

## Diagnostic Commands (Using k9s)

> **Tip**: Launch k9s by typing `k9s` in your terminal. Press `?` at any time to see available keyboard shortcuts.

### k9s Quick Reference

| Key | Action |
|-----|--------|
| `:` | Command mode (type resource names) |
| `/` | Filter/search within current view |
| `Enter` | Select/drill into resource |
| `d` | Describe selected resource |
| `l` | View logs for selected pod |
| `p` | View previous container logs |
| `y` | View YAML definition |
| `e` | Edit resource |
| `Ctrl+d` | Delete resource |
| `Esc` | Go back / cancel |
| `0-9` | Switch to namespace by number |

### k9s Log View Shortcuts

| Key | Action |
|-----|--------|
| `0` | Show ALL logs (no tail limit) - **use this if you see "Waiting for logs..."** |
| `1-5` | Tail last 100/500/1000/5000/10000 lines |
| `s` | Toggle auto-scroll |
| `w` | Toggle line wrap |
| `t` | Toggle timestamps |
| `f` | Toggle fullscreen |
| `/` | Search within logs |
| `n` | Next search match |
| `N` | Previous search match |
| `p` | View previous container logs |
| `c` | Clear log view |

> **⚠️ Common Gotcha**: "Waiting for logs..." usually means the container hasn't produced *recent* logs, not that it's frozen. Press `0` to show all logs regardless of tail setting.

### 1. Check Pod Status and Logs

```
# In k9s, switch to azure-iot-operations namespace:
:ns                              # Opens namespace view
/azure-iot-operations            # Filter to find the namespace
Enter                            # Select to switch to it

# View all pods (default view after selecting namespace):
:pods                            # Or just :po

# Find the HTTP connector pod:
/http-connector                  # Filter pods by name

# View pod details:
d                                # Describe the selected pod

# View pod logs:
l                                # Opens log view for selected pod
  - Press 's' to toggle auto-scroll
  - Press 'w' to toggle wrap
  - Press '0' to show all log lines
  - Press 'p' to view previous container logs
  - Press '/' to search within logs
```

### 2. Check Asset and Asset Endpoint Status

```
# View all assets:
:assets                          # Lists all Asset resources
/demohistorian                   # Filter to find your asset

# Describe the asset:
d                                # Shows detailed status and events

# View asset YAML:
y                                # Shows full YAML definition

# View asset endpoints:
:assetendpointprofiles           # Or :aep if alias is configured
/demohistorian                   # Filter to find endpoint
d                                # Describe the endpoint
```

### 3. Check Dataset Configuration

```
# View asset YAML to inspect dataset configuration:
:assets
/demohistorian-asset
y                                # View full YAML - look for 'datasets:' section

# Check events related to assets:
:events                          # View all events in namespace
/demohistorian                   # Filter for asset-related events
```

### 4. Check Dataflow and Dataflow Endpoints

```
# View dataflows:
:dataflows                       # Lists all Dataflow resources
d                                # Describe selected dataflow

# View dataflow endpoints:
:dataflowendpoints
d                                # Describe selected endpoint
y                                # View YAML configuration
```

### 5. Quick Navigation Tips

```
# Jump directly to a resource type:
:deploy                          # Deployments
:svc                             # Services
:cm                              # ConfigMaps
:secrets                         # Secrets
:events                          # Events (sorted by time)
:crd                             # Custom Resource Definitions

# View all AIO-related CRDs:
:crd
/deviceregistry                  # Filter for device registry CRDs

# Pulse view (cluster overview):
:pulse                           # Shows cluster health summary

# XRay view (resource tree):
:xray deploy                     # Shows deployment hierarchy
```

---

## Issue: Asset Visible in Portal but Not in Kubernetes

**Symptom:**
- Asset shows in AIO Portal
- `:assets` in k9s shows `[0]` - no assets
- HTTP connector logs show errors referencing the asset

This indicates a **sync failure** between Azure Resource Manager (ARM) and the Arc-connected Kubernetes cluster.

### Diagnostic Steps

```
# 1. Check if the Asset CRD exists:
:crd
/asset
# Should see: assets.deviceregistry.microsoft.com

# 2. Check Device Registry operator status:
:pods
/device-registry
d                                # Describe - look for errors

# 3. Check extension status:
:pods
/extension
# Look for arc-extension pods

# 4. Check Azure Arc agent health:
:pods
# Switch namespace to azure-arc
:ns
/azure-arc
Enter
:pods                            # All pods should be Running
```

### Common Causes

| Cause | How to Identify | Solution |
|-------|-----------------|----------|
| **Arc agent disconnected** | Arc pods not running or erroring | Reconnect cluster to Arc |
| **Device Registry extension unhealthy** | device-registry pods failing | Reinstall/repair the extension |
| **RBAC permissions** | Extension can't sync resources | Check managed identity permissions |
| **Custom locations issue** | Sync happens via custom location | Verify custom location is enabled |
| **Network connectivity** | Cluster can't reach Azure | Check outbound connectivity |

### Check Arc Connection Status

```bash
# On the edge device (or from Windows with kubeconfig):
az connectedk8s show --name <cluster-name> --resource-group <rg> --query connectivityStatus

# Should return: "Connected"
```

### Check Custom Location Status

```bash
# The custom location enables Azure resources to sync to the cluster:
az customlocation show --name <custom-location-name> --resource-group <rg> --query "provisioningState"

# Should return: "Succeeded"
```

### Check Device Registry Extension

```bash
# List extensions on the Arc cluster:
az k8s-extension list --cluster-name <cluster-name> --resource-group <rg> --cluster-type connectedClusters

# Look for: microsoft.deviceregistry.assets
# Check provisioningState should be "Succeeded"
```

### Force Resync (if needed)

Sometimes Azure resources need to be "touched" to trigger a resync:

1. **In Azure Portal**: Edit the asset, make a trivial change, save
2. **Via CLI**: Update a property on the asset
3. **Delete and recreate**: Remove the asset in portal, recreate it

### Verify the Issue with Azure CLI

```bash
# Check if asset exists in ARM:
az iot ops asset show --name demohistorian-asset --resource-group <rg>

# If it exists in ARM but not in k8s, the sync is broken
```

---

## Issue: HTTP Connector Container Shows "Waiting for logs..."

**Symptom:**
In k9s, the HTTP connector pod logs show only:
```
Waiting for logs...
```

This indicates the container is not producing output, which can have several causes:

### Diagnostic Steps in k9s

```
# Check pod status - look for the STATUS column
:pods
/azureiotoperationsconnectorforresthttp

# Key statuses to look for:
# - Running (but no logs) → Container may be blocked/frozen
# - Init:0/1 → Stuck in init container
# - CrashLoopBackOff → Container crashing before logging
# - Pending → Resource issues (CPU/memory limits)

# Describe the pod for detailed status:
d

# Look for:
# - Events at the bottom (scheduling issues, pull errors)
# - Container State (Waiting, Running, Terminated)
# - Last State (if it crashed before)
# - Ready status (true/false)
```

### Common Causes

| Cause | How to Identify | Solution |
|-------|-----------------|----------|
| **Init container stuck** | Status shows `Init:0/1` or similar | Check init container logs: select pod → `l` → choose init container |
| **Waiting for dependencies** | Pod Running but container waiting | Check if MQTT broker, secrets, or endpoints are available |
| **Configuration error** | Container starts then stops | Check previous logs with `p` key |
| **Resource limits** | Pod Pending or Evicted | Check node resources with `:nodes` then `d` |
| **Image pull issues** | ImagePullBackOff status | Check image name and registry access |
| **Secret/ConfigMap missing** | Container stuck in ContainerCreating | Check events for missing volume mounts |

### Check Init Containers

```
# In k9s, when viewing pod logs:
l                                # Open logs
# If multiple containers, you'll see a menu - select init containers first

# Or describe the pod to see init container status:
d
# Look for "Init Containers:" section
```

### Check Container State Details

```
# View pod YAML for detailed state:
y
# Search for 'state:' to see:
#   state:
#     waiting:
#       reason: "SomeReason"
#       message: "Detailed error message"
```

### Check Related Resources

```
# The HTTP connector needs these to be healthy:

# 1. Check MQTT broker is running:
:pods
/mq

# 2. Check secrets are available:
:secrets
/demohistorian                   # Or your endpoint name

# 3. Check the asset endpoint status:
:assetendpointprofiles
/demohistorian
d                                # Look for status conditions

# 4. Check for any cluster-wide issues:
:events
/Warning                         # Filter for warning events
```

### Force Container Restart

```
# In k9s, delete the pod to force a restart:
:pods
/azureiotoperationsconnectorforresthttp
Ctrl+d                           # Delete pod (StatefulSet will recreate)

# Or scale the StatefulSet:
:statefulsets                    # Or :sts
/azureiotoperationsconnectorforresthttp
s                                # Scale - set to 0, then back to 1
```

### Check StatefulSet Status

```
:statefulsets
/azureiotoperationsconnectorforresthttp
d                                # Describe to see replica status and events
```

---

## Common Causes of "Failed to parse dataset configuration"

### 1. Invalid Dataset Schema
- **Cause**: The dataset configuration has malformed JSON or YAML
- **Check**: Validate the asset's dataset definition in the YAML
- **Solution**: Ensure proper formatting of `datasets` section in asset definition

### 2. Incorrect Data Point Specification
- **Cause**: Data points in the dataset don't match expected format
- **Check**: Verify `dataPoints` array structure
- **Solution**: Each data point needs: `name`, `dataSource`, `observabilityMode`

### 3. Missing Required Fields
- **Cause**: Required fields are missing from dataset configuration
- **Check**: Ensure `datasetConfiguration` contains required schema fields
- **Solution**: Add missing fields as per AIO asset schema

### 4. Type Mismatches
- **Cause**: Field types don't match expected types (string vs integer, etc.)
- **Check**: Review ARM template or YAML for type definitions
- **Solution**: Correct field types in the configuration

### 5. Invalid JSON in datasetConfiguration
- **Cause**: The `datasetConfiguration` field contains invalid JSON string
- **Check**: Validate JSON using an online JSON validator
- **Solution**: Fix JSON syntax errors (missing quotes, commas, brackets)

---

## Inspecting the Asset Definition

Review your asset definition for proper structure:

```yaml
apiVersion: deviceregistry.microsoft.com/v1
kind: Asset
metadata:
  name: demohistorian-asset
  namespace: azure-iot-operations
spec:
  assetEndpointProfileRef: demohistorian-endpoint
  datasets:
    - name: demohistorian-health
      datasetConfiguration: '{"publishingInterval": 1000}'  # Must be valid JSON string
      dataPoints:
        - name: health
          dataSource: /health
          observabilityMode: log
```

### Key Points to Verify:
1. `datasetConfiguration` must be a valid JSON **string** (note the quotes)
2. Each `dataPoint` must have required fields
3. `dataSource` paths must be valid for the endpoint type
4. `observabilityMode` must be one of: `none`, `gauge`, `counter`, `histogram`, `log`

---

## Checking the Asset Endpoint Profile

```bash
kubectl get assetendpointprofile demohistorian-endpoint -n azure-iot-operations -o yaml
```

Verify:
- `targetAddress` is correctly formatted for HTTP endpoints
- Authentication settings are properly configured
- Transport settings match the target service

---

## Additional Diagnostic Steps

### Check AIO Operator Logs

```bash
# Find the AIO operator pod
kubectl get pods -n azure-iot-operations | grep -i operator

# View operator logs
kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-operator
```

### Check for Resource Validation Errors

```bash
# Get all events sorted by time
kubectl get events -n azure-iot-operations --sort-by='.lastTimestamp'

# Filter for warnings
kubectl get events -n azure-iot-operations --field-selector type=Warning
```

### Verify Schema Registry Configuration

```bash
# Check if schema registry is properly configured
kubectl get schemaregistries -n azure-iot-operations

# Describe schema registry
kubectl describe schemaregistry <name> -n azure-iot-operations
```

---

## Portal Troubleshooting

When the portal shows generic errors like "Health status: An error occurred":

1. **Check Pod Logs First**: The portal error is usually a summary; detailed errors are in pod logs
2. **Use Azure Portal Resource Health**: Navigate to your AIO instance → Resource Health
3. **Check Activity Log**: Azure Portal → Your AIO Resource → Activity Log for deployment errors
4. **Review Metrics**: Azure Portal → Your AIO Resource → Metrics for operational data

---

## Fixing Dataset Configuration Issues

### Step 1: Export Current Configuration

```bash
kubectl get asset demohistorian-asset -n azure-iot-operations -o yaml > demohistorian-asset-backup.yaml
```

### Step 2: Validate and Fix

Edit the YAML file and ensure:
- JSON strings are properly escaped
- All required fields are present
- Data types are correct

### Step 3: Apply Fixed Configuration

```bash
kubectl apply -f demohistorian-asset-fixed.yaml
```

### Step 4: Verify Fix

```bash
# Check asset status
kubectl get asset demohistorian-asset -n azure-iot-operations

# Watch for status changes
kubectl get asset demohistorian-asset -n azure-iot-operations -w

# Check pod logs for success
kubectl logs -n azure-iot-operations -l app=aio-http-connector -f
```

---

## Related Resources

- [Azure IoT Operations Documentation](https://learn.microsoft.com/azure/iot-operations/)
- [Asset Configuration Reference](https://learn.microsoft.com/azure/iot-operations/manage-devices-assets/overview-manage-assets)
- [Troubleshooting Azure IoT Operations](https://learn.microsoft.com/azure/iot-operations/troubleshoot/troubleshoot)

---

## Notes

_Add your investigation notes here as you troubleshoot:_

- Date: 
- Issue: 
- Root Cause: 
- Resolution: 
