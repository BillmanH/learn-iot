# OPC UA Bridge Setup Guide

## Overview

This guide provides the **recommended approach** for integrating factory MQTT data with Azure IoT Operations using an OPC UA bridge. This enables full portal integration with asset registration, dashboards, and data flow configuration.

## Why Use OPC UA Bridge?

Azure IoT Operations is designed around OPC UA for industrial asset integration. The bridge approach provides:

- ✅ **Full Portal Integration** - Register assets in Azure IoT Operations portal
- ✅ **Asset Endpoint Compliance** - Meet `opc.tcp://` URL requirements
- ✅ **Built-in Dashboards** - Use Azure IoT Operations native dashboards
- ✅ **Data Flow Configuration** - Configure processing through portal UI
- ✅ **Asset Lifecycle Management** - Complete asset management through portal

## Architecture

```
SpaceShip Factory MQTT → OPC PLC Simulator → Azure IoT Operations Portal
        ↓                       ↓                        ↓
- factory/cnc              - opc.tcp://           - Asset Registration
- factory/3dprinter        - OPC UA nodes         - Dashboard Configuration
- factory/welding          - Data mapping         - Data Flow Setup
- factory/painting         - Node simulation      - Alert Configuration
- factory/testing          - Real-time sync       - Analytics & Reporting
```

## Step 1: Deploy OPC PLC Simulator

The Microsoft OPC PLC Simulator provides the required `opc.tcp://` endpoint for Azure IoT Operations.

### OPC PLC Deployment Configuration

The OPC PLC simulator is configured in [`opc-plc-simulator.yaml`](./opc-plc-simulator.yaml) and includes:

- **Deployment**: Microsoft OPC PLC container with factory node definitions
- **Service**: ClusterIP service exposing OPC UA endpoint on port 50000  
- **ConfigMap**: Factory node definitions matching your MQTT data structure

#### Configuration Requirements

Before deploying, verify these settings match your environment:

1. **Namespace**: Ensure `azure-iot-operations` namespace exists
   ```bash
   kubectl get namespace azure-iot-operations
   # If not found: kubectl create namespace azure-iot-operations
   ```

2. **Node IDs**: The ConfigMap defines OPC UA nodes that map to your MQTT topics:
   - `factory/cnc` → `ns=2;s=CNC01.*` nodes
   - `factory/3dprinter` → `ns=2;s=3DP05.*` nodes  
   - `factory/welding` → `ns=2;s=WELD02.*` nodes
   - `factory/painting` → `ns=2;s=PAINT01.*` nodes
   - `factory/testing` → `ns=2;s=TEST01.*` nodes

If you have varied from the OPC


3. **Security Settings**: Currently configured for development with:
   - `--unsecuretransport` (no encryption)
   - `--autoaccept` (auto-accept client certificates)
   
   **For production**: Remove these flags and configure proper certificates.

4. **Port Configuration**: Default OPC UA port 50000
   - Update if your environment requires different ports
   - Ensure port is available and not blocked by firewall

### Deploy the OPC UA Server

```bash
# Apply the OPC PLC simulator from the configuration file
kubectl apply -f opc-plc-simulator.yaml

# Verify deployment
kubectl get pods -n azure-iot-operations -l app=opc-plc-simulator
kubectl get svc -n azure-iot-operations opc-plc-service

# Check OPC UA endpoint accessibility
kubectl exec -it deployment/opc-plc-simulator -n azure-iot-operations -- netstat -tlnp | grep 50000
```

## Step 2: Create Asset Endpoint Profile

Create the Asset Endpoint Profile to connect Azure IoT Operations to the OPC UA server:

The endpoint profile is configured in [`asset-endpoint-profile.yaml`](./asset-endpoint-profile.yaml) with:

- **Target Address**: Points to the OPC PLC service within the cluster
- **Authentication**: Anonymous (development setup)
- **Security**: None (for development - configure certificates for production)

#### Configuration Notes

1. **Service DNS**: Uses Kubernetes internal DNS: `opc-plc-service.azure-iot-operations.svc.cluster.local:50000`
2. **Security Settings**: Currently uses `None` for development
   - **For production**: Configure security policy and mode with proper certificates
3. **Timeouts**: Configured for stable connection management
   - `sessionTimeout`: 60 seconds
   - `sessionKeepAliveInterval`: 10 seconds

```bash
# Apply the asset endpoint profile
kubectl apply -f asset-endpoint-profile.yaml

# Verify endpoint profile
kubectl get assetendpointprofile -n azure-iot-operations
```

## Step 3: Portal Asset Registration

### Navigate to Azure IoT Operations Portal

1. Open [Azure Portal](https://portal.azure.com)
2. Navigate to your IoT Operations instance: `iot-operations-work-edge-bel-aio/bel-aio-work-cluster`
3. Select **"Asset endpoints"** → Verify `spaceship-factory-opcua` endpoint appears
4. Select **"Assets"** → Click **"+ Add asset"**

### Register Factory Assets

Use the asset definitions from `asset-examples.md` with these portal settings:

#### Asset Endpoint Configuration
- **Asset endpoint**: `spaceship-factory-opcua`
- **OPC UA server URL**: `opc.tcp://opc-plc-service.azure-iot-operations.svc.cluster.local:50000`

#### Sample Asset Registration (CNC Machine)
- **Asset name**: `CNC-LINE-1-STATION-A`
- **Description**: `CNC machining station for precision part manufacturing`
- **Asset endpoint**: `spaceship-factory-opcua`

**Datapoints**:
- `machine_id` → Node ID: `ns=2;s=CNC01.MachineId`
- `status` → Node ID: `ns=2;s=CNC01.Status`  
- `part_type` → Node ID: `ns=2;s=CNC01.PartType`
- `quality` → Node ID: `ns=2;s=CNC01.Quality`
- `cycle_time` → Node ID: `ns=2;s=CNC01.CycleTime`

## Step 4: Configure Data Processing

### Option A: Portal Data Flow Configuration
1. Navigate to **Data flows** in Azure IoT Operations portal
2. Create new data flow with source: `spaceship-factory-opcua`
3. Configure transformations for OEE calculations
4. Set destination for processed data

### Option B: MQTT-to-OPC Bridge (Advanced)
For real-time MQTT data synchronization with OPC UA nodes, deploy a custom bridge service (see advanced configuration section).

## Step 5: Dashboard and Analytics Setup

### Built-in Portal Dashboards
1. Navigate to **Dashboards** in Azure IoT Operations portal
2. Create dashboard with registered assets as data sources
3. Add widgets for:
   - Real-time asset status
   - OEE metrics by machine
   - Quality trends
   - Production throughput

### Custom Analytics
Configure custom KQL queries and Power BI integration through the portal data export features.

## Verification and Testing

### Verify OPC UA Connectivity
```bash
# Check OPC UA server status
kubectl get pods -n azure-iot-operations -l app=opc-plc-simulator

# Test OPC UA endpoint
kubectl exec -it deployment/opc-plc-simulator -n azure-iot-operations -- netstat -tlnp | grep 50000

# Verify asset endpoint profile
kubectl describe assetendpointprofile spaceship-factory-opcua -n azure-iot-operations
```

### Test Asset Registration
```bash
# Check registered assets
kubectl get assets -n azure-iot-operations
kubectl describe asset cnc-line-1-station-a -n azure-iot-operations
```

### Monitor Data Flow
1. In Azure IoT Operations portal, navigate to **Assets**
2. Select a registered asset
3. View real-time datapoint values
4. Check data flow status and metrics

## Troubleshooting

### Common Issues

1. **Pod CrashLoopBackOff - Permission Denied**: 
   - **Symptom**: `System.UnauthorizedAccessException: Access to the path '/app/pki' is denied`
   - **Cause**: OPC PLC simulator cannot create certificate directory due to insufficient permissions
   - **Solution**: The YAML configuration has been updated with proper security context and writable volume mounts

2. **Asset Endpoint Not Found**: Verify OPC PLC simulator is running and service is accessible
3. **Node Connection Errors**: Check OPC UA node IDs match the ConfigMap definitions  
4. **Authentication Failures**: Ensure Anonymous authentication is configured correctly
5. **Data Not Flowing**: Verify asset datapoint mappings and OPC UA node accessibility

### Fix for CrashLoopBackOff Issue

If you're experiencing pod crashes with permission errors, apply the updated configuration:

```bash
# Delete the existing deployment
kubectl delete deployment opc-plc-simulator -n azure-iot-operations

# Apply the corrected configuration with proper security context
kubectl apply -f opc-plc-simulator.yaml

# Verify the fix
kubectl get pods -n azure-iot-operations -l app=opc-plc-simulator
kubectl logs deployment/opc-plc-simulator -n azure-iot-operations
```

The updated configuration includes:
- **Security Context**: Runs as non-root user with proper permissions
- **PKI Storage**: Writable volume mount for certificate storage at `/tmp/pki`  
- **Resource Limits**: Memory and CPU limits to prevent resource conflicts
- **PKI Directory Override**: Uses `--pki=/tmp/pki` argument for writable location

### Debug Commands

```bash
# Check OPC UA server logs
kubectl logs deployment/opc-plc-simulator -n azure-iot-operations

# Test internal connectivity
kubectl exec -it deployment/spaceshipfactorysim -n default -- nslookup opc-plc-service.azure-iot-operations.svc.cluster.local

# Verify asset endpoint profile status
kubectl get assetendpointprofile spaceship-factory-opcua -n azure-iot-operations -o yaml | grep -A 10 status
```

## Next Steps

1. **Complete Asset Registration** - Register all factory assets using `asset-examples.md`
2. **Configure Portal Dashboards** - Set up monitoring and analytics in Azure IoT Operations portal  
3. **Set Up Data Flows** - Configure data processing and routing through portal UI
4. **Implement Alerting** - Create alerts for asset health and OEE thresholds
5. **Integrate with External Systems** - Export data to Power BI, Azure Data Explorer, or other analytics platforms

This approach provides full Azure IoT Operations portal integration while maintaining your existing MQTT-based factory simulation!