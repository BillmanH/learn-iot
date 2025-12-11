# Azure IoT Operations - Portal Device Discovery

This guide walks through discovering and managing devices via the Azure Portal for your AIO instance.

## Important Discovery Notes

⚠️ **Discovery requires active MQTT publishers**: The "Devices" tab shows endpoint profiles, but discovery only works if you have applications actively publishing telemetry to MQTT topics. 

**Current Status:**
- ✅ Asset endpoint profile created (`factory-mqtt`) with discovery enabled
- ✅ Static asset created via ARM (`factory-mqtt-asset`)
- ⚠️ No active MQTT publisher deployed yet (edgemqttsim not running)
- ❌ Portal shows "You currently do not have resources" because no telemetry is being published

**To enable discovery, you must first deploy a telemetry publisher** (see Step 0 below).

## Prerequisites

- Azure IoT Operations instance deployed (`bel-aio-work-cluster`)
- MQTT Asset Endpoint Profile with discovery enabled (`factory-mqtt`)
- **MQTT publisher application running** (edgemqttsim or similar)
- MQTT broker running (aio-broker)
- Resource Group: `IoT-Operations-Work-Edge-bel-aio`

## Device Discovery Steps

### Step 0: Deploy MQTT Publisher (Required First!)

Before discovery can work, you need an application publishing telemetry to MQTT topics.

**Deploy the edgemqttsim application:**

```bash
# On your edge device
cd ~/operations/learn-iot/iotopps/edgemqttsim

# Build and push the container image (if not already done)
# Update <YOUR_REGISTRY> in deployment.yaml first
docker build -t <YOUR_REGISTRY>/edgemqttsim:latest .
docker push <YOUR_REGISTRY>/edgemqttsim:latest

# Deploy to Kubernetes
kubectl apply -f deployment.yaml

# Verify it's running
kubectl get pods -n default | grep edgemqttsim
kubectl logs -n default <edgemqttsim-pod-name>
```

**Verify MQTT messages are being published:**

First, deploy an MQTT debug client (if not already deployed):
```bash
kubectl apply -f ~/operations/learn-iot/linux_build/assets/mqtt-debug-client.yaml
kubectl wait --for=condition=Ready pod/mqtt-debug-client -n azure-iot-operations --timeout=60s
```

Then subscribe to factory topics:
```bash
kubectl exec -it -n azure-iot-operations mqtt-debug-client -- \
  mosquitto_sub -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t 'factory/#' -v
```

You should see messages like:
```
factory/cnc {"machine_id": "cnc-01", "temperature": 45.2, "status": "running"}
factory/3dprinter {"machine_id": "3dp-01", "temperature": 210.5, "status": "printing"}
```

### Step 1: Navigate to Sites

1. Go to [Azure Portal](https://portal.azure.com)
2. In the search bar, type **"Sites"** and select **Sites** from the results
3. Or navigate directly to: `Home > Sites`

### Step 1: Navigate to Sites

1. Go to [Azure Portal](https://portal.azure.com)
2. In the search bar, type **"Sites"** and select **Sites** from the results
3. Or navigate directly to: `Home > Sites`

### Step 2: Access Unassigned Instances

1. In the Sites view, locate and click **"Unassigned instances"**
2. Find your cluster: **`bel-aio-work-cluster`**
3. Click on the cluster name to open its details

### Step 3: View Devices Tab

1. In the cluster details view, click the **"Devices"** tab
2. You should see your endpoint profile: **`factory-mqtt`**
3. Check that **"Enable discovery"** shows as **Enabled**

**Note:** The "Devices" tab shows endpoint profiles, not individual assets. If you see "You currently do not have resources", it means no telemetry is flowing yet (see Step 0).

### Step 4: Check Existing Assets

Since you deployed `factory-mqtt-asset` via ARM, check if it's already visible:

1. Go to your Resource Group in the portal
2. Look for **`factory-mqtt-asset`** in the resources list
3. Click on it to view details
4. Check the **"Telemetry"** or **"Data"** tab to see if data is flowing

**Asset Portal Link:**
https://portal.azure.com/#@/resource/subscriptions/5c043aac-3d88-43d5-aec8-cd02ee6c914a/resourceGroups/IoT-Operations-Work-Edge-bel-aio/providers/Microsoft.DeviceRegistry/assets/factory-mqtt-asset/overview

### Step 5: Automatic Discovery (If Available)

⚠️ **Note:** If there's no explicit "Discover" button in the portal, discovery may happen automatically when:
- The endpoint profile has `discoveryEnabled: true` (✅ you have this)
- MQTT messages are actively being published (❌ you need to deploy edgemqttsim)
- Messages follow a discoverable topic pattern (✅ factory/* topics)

Discovery typically works by monitoring MQTT topics and automatically creating asset suggestions based on the data structure.

## Troubleshooting Discovery

### Discovery Not Finding Devices

**Check MQTT Topics:**
```bash
# On the edge device
kubectl exec -it <mqtt-client-pod> -n azure-iot-operations -- sh
mosquitto_sub -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t '#' -v
```

**Verify Endpoint Profile:**
```bash
az resource show \
  --ids "/subscriptions/<subscription-id>/resourceGroups/IoT-Operations-Work-Edge-bel-aio/providers/Microsoft.DeviceRegistry/assetEndpointProfiles/factory-mqtt" \
  --query "properties.discoveryEnabled"
```

Should return: `true`

**Check Broker Connectivity:**
```bash
kubectl get pods -n azure-iot-operations | grep broker
kubectl logs -n azure-iot-operations <broker-pod-name>
```

### Discovery is Enabled but No Devices Appear

1. **Verify MQTT messages are being published:**
   - Check that your edge applications are running
   - Verify they're publishing to the correct broker URL
   - Confirm topic structure matches expectations

2. **Check topic patterns:**
   - Discovery looks for specific MQTT topic patterns
   - Default pattern: `<prefix>/<device-id>/<data-point>`
   - Ensure your topics follow a discoverable structure

3. **Wait for sync:**
   - Discovery may take 1-2 minutes to complete
   - Refresh the portal page
   - Try clicking "Discover" again

## Next Steps

After discovering and adding devices as assets:

1. **Configure Data Flow:**
   - Set up data pipelines to send telemetry to Azure Data Explorer, Event Hubs, or Fabric
   
2. **Set Up Alerts:**
   - Create alert rules for critical telemetry values
   
3. **Monitor Performance:**
   - Use Azure Monitor to track device health
   - View historical telemetry in Azure Data Explorer

4. **Organize into Sites:**
   - Group assets by physical location or logical grouping
   - Assign assets to specific sites for better organization

## Useful Portal Links

- **Resource Group:** https://portal.azure.com/#@/resource/subscriptions/5c043aac-3d88-43d5-aec8-cd02ee6c914a/resourceGroups/IoT-Operations-Work-Edge-bel-aio/overview
- **MQTT Asset:** https://portal.azure.com/#@/resource/subscriptions/5c043aac-3d88-43d5-aec8-cd02ee6c914a/resourceGroups/IoT-Operations-Work-Edge-bel-aio/providers/Microsoft.DeviceRegistry/assets/factory-mqtt-asset/overview

## CLI Alternative

You can also discover and list assets using Azure CLI:

```bash
# List all assets
az resource list \
  --resource-group IoT-Operations-Work-Edge-bel-aio \
  --resource-type Microsoft.DeviceRegistry/assets \
  -o table

# Get asset details
az resource show \
  --ids "/subscriptions/<subscription-id>/resourceGroups/IoT-Operations-Work-Edge-bel-aio/providers/Microsoft.DeviceRegistry/assets/factory-mqtt-asset"
```
