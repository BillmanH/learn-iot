# Bug Report: Azure IoT Operations Portal Blocks HTTP REST Asset Creation

## Issue Summary
The Azure IoT Operations portal shows validation error "Unable to retrieve valid datapoints" and disables the "Apply" button when configuring HTTP REST assets with cluster-internal URLs. This blocks legitimate use cases where the HTTP endpoint is only accessible within the Kubernetes cluster.

## Environment
- **Azure IoT Operations Version**: 1.2.154
- **Kubernetes**: K3s v1.34.3+k3s1
- **Location**: westus2
- **Instance Name**: iot-ops-cluster-aio
- **Resource Group**: IoT-Operations
- **Namespace**: iot-operations-ns

## Expected Behavior
Portal should allow creating HTTP REST assets with cluster-internal URLs (e.g., `http://service.namespace.svc.cluster.local:port`) since:
1. The HTTP connector runs **inside the cluster** and can reach these URLs
2. Portal validation runs from Azure cloud and cannot reach cluster-internal services
3. Runtime behavior is correct despite portal validation failure

## Actual Behavior
- Portal shows error: **"Unable to retrieve valid datapoints - The selected source may not be configured correctly"**
- **Apply button is greyed out** and dataflow cannot be created
- Error occurs during schema validation when portal tries to reach cluster-internal URL from Azure

## Proof That Configuration is Correct

### 1. Device Configuration (Working)
```bash
az iot ops ns device show -n demohistorian-device --instance iot-ops-cluster-aio -g IoT-Operations
```
**Output**:
```json
{
  "enabled": true,
  "provisioningState": "Succeeded",
  "properties": {
    "endpoints": {
      "inbound": {
        "historian-http": {
          "endpointType": "Microsoft.Http",
          "address": "http://demohistorian.default.svc.cluster.local:8080",
          "authentication": {
            "method": "Anonymous"
          }
        }
      }
    }
  }
}
```

### 2. Asset Configuration (Enabled)
```bash
az iot ops ns asset show -n demohistorian-asset --instance iot-ops-cluster-aio -g IoT-Operations
```
**Output**:
```json
{
  "enabled": true,
  "provisioningState": "Succeeded",
  "properties": {
    "deviceRef": {
      "deviceName": "demohistorian-device",
      "endpointName": "historian-http"
    },
    "datasets": [
      {
        "name": "health-status",
        "dataSource": "/health",
        "datasetConfiguration": "{\"samplingIntervalInMilliseconds\": 30000}",
        "destinations": [
          {
            "target": "Mqtt",
            "configuration": {
              "topic": "historian/health",
              "qos": "Qos1",
              "retain": "Never",
              "ttl": 3600
            }
          }
        ]
      },
      {
        "name": "factory-lastvalue",
        "dataSource": "/api/v1/query?topic=factory/cnc",
        "datasetConfiguration": "{\"samplingIntervalInMilliseconds\": 60000}",
        "destinations": [
          {
            "target": "Mqtt",
            "configuration": {
              "topic": "historian/lastvalue/factory",
              "qos": "Qos1",
              "retain": "Keep",
              "ttl": 7200
            }
          }
        ]
      }
    ]
  }
}
```

### 3. HTTP Endpoint is Reachable From Cluster
**Test from within cluster**:
```bash
kubectl exec -n default demohistorian-575798df58-4n5qk -c historian -- python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/health').read().decode())"
```
**Output**:
```json
{"status":"healthy","mqtt_connected":true,"db_connected":true,"messages_stored":22168,"timestamp":"2026-01-24T00:38:42.495715Z"}
```

### 4. HTTP Connector Template Exists
```bash
kubectl get connectortemplate -n azure-iot-operations
```
**Output**:
```
NAME                                          AGE
azureiotoperationsconnectorformqtt-5609       3h46m
azureiotoperationsconnectorforresthttp-4627   3h46m
```

**Template Status**:
```bash
kubectl describe connectortemplate azureiotoperationsconnectorforresthttp-4627 -n azure-iot-operations
```
```
Status:
  Provisioning Status:
    Status:  Succeeded
    Message: ConnectorTemplate created successfully
```

### 5. Service is Running and Healthy
```bash
kubectl get service demohistorian -n default
```
**Output**:
```
NAME            TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
demohistorian   ClusterIP   10.43.132.124   <none>        8080/TCP   3h
```

```bash
kubectl get pods -n default -l app=demohistorian
```
**Output**:
```
NAME                             READY   STATUS    RESTARTS   AGE
demohistorian-575798df58-4n5qk   2/2     Running   4          3h
```

## Problem Identified

**HTTP Connector Instance NOT Created**: Despite device and asset being enabled, no connector instance exists:
```bash
kubectl get connector -n azure-iot-operations
```
**Output**:
```
NAME                                               AGE
azureiotoperationsconnectorformqtt-5609-232b7ab5   99m
```
*Note: Only MQTT connector exists, no HTTP connector instance*

**Asset Status is Null**: The asset shows `"status": null`, indicating it's not being processed by the connector.

## Root Cause Analysis

1. **Portal validation attempts to reach cluster-internal URL from Azure cloud** (fails as expected)
2. **Portal blocks UI preventing dataflow creation** despite valid configuration
3. **Even with CLI-based asset creation, HTTP connector instance is not spawned**
4. **Asset remains in null status** - no connector processing occurs

## Workarounds Attempted

### ❌ Failed: NodePort Exposure
- Changed service to NodePort (`kubectl patch service demohistorian -n default -p '{"spec":{"type":"NodePort"}}'`)
- NodePort: 31287 on node IP: 10.91.137.76
- Still fails portal validation (home network not accessible from Azure)

### ❌ Failed: CLI Asset Creation
- Created device via CLI: `az iot ops ns device create`
- Created asset via CLI: `az iot ops ns asset rest create`
- Added datasets via CLI: `az iot ops ns asset rest dataset add`
- **Result**: Asset created but connector instance never spawns

## Expected Fix

Portal should:
1. **Allow creating dataflows with cluster-internal URLs** 
2. **Show warning instead of error** for unreachable URLs during validation
3. **Enable the Apply button** with disclaimer that validation couldn't complete
4. **Trigger connector instance creation** when device is enabled (currently not happening)

## Reproduction Steps

1. Deploy Azure IoT Operations to Arc-enabled Kubernetes cluster
2. Create HTTP REST service accessible at `http://service.namespace.svc.cluster.local:port`
3. In Azure Portal → IoT Operations → Devices: Create device with HTTP inbound endpoint using cluster-internal URL
4. In Azure Portal → IoT Operations → Assets: Create asset using the HTTP device
5. Add dataset with data source path (e.g., `/health`)
6. Observe validation error and disabled Apply button

## Related Issues

- Portal validation is designed for external URLs
- No provision for cluster-internal services
- Connector instance creation appears broken even when bypassing portal

## Additional Context

**Documentation Reference**: 
- [Configure the connector for HTTP/REST](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/howto-use-http-connector)
- HTTP/REST connector is officially supported feature
- Documentation doesn't mention portal limitations for cluster-internal URLs

**Customer Impact**: 
- Blocks legitimate use cases for edge-to-cloud data pipelines
- Forces workarounds that expose internal services unnecessarily
- Prevents using HTTP REST assets for querying local APIs (historians, databases, REST endpoints)

## Requested Action

1. **Immediate**: Allow portal dataflow creation with warning instead of blocking error
2. **Short-term**: Fix connector instance creation when device is enabled
3. **Long-term**: Implement proper validation that distinguishes between:
   - External URLs (can validate from portal)
   - Cluster-internal URLs (skip validation, show warning)

## Attachments

- Device configuration JSON
- Asset configuration JSON  
- Connector template status
- Service and pod status
- Endpoint health response

---

**Reporter**: GitHub Copilot User  
**Date**: 2026-01-24  
**Priority**: High (Blocks feature usage)
