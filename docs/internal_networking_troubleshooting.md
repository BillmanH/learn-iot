# Internal Networking Troubleshooting

## Variables

Set these before running the steps below:

```powershell
# --- Remote connection variables ---
$NucClusterName     = "iot-ops-cluster"
$NucResourceGroup   = "IoT-Operations"
$ThinkClusterName   = "iot-ops-cluster"
$ThinkResourceGroup = "msft-thinkstation-ot-rg"
# ThinkStation is local — no remote connection needed

# --- Cluster / AIO variables ---
$Namespace          = "azure-iot-operations"
$DataflowName       = "nuc-to-thinkstation"
$EndpointName       = "thinkstation"
$SourceTopic        = "factory/#"
$RelayedTopic       = "nuc/factory/#"  # topic the NUC dataflow writes to on ThinkStation
$SimAppLabel        = "edgemqttsim"
$ListenerService    = "publiclistener"
$BrokerHost         = "localhost"
$BrokerPort         = 1883
$DataflowPodLabel   = "app=aio-dataflow"
$SampleMessageCount = 5
```

---

## Login to Azure

```powershell
az login --tenant 1c1264ca-77ff-400d-9608-c7305f777319
```

---

## Step 0: Verify Both Clusters Are Connected to Azure Arc

Run from the ThinkStation to confirm both clusters are online:

```powershell
# Check NUC cluster
az connectedk8s show --name $NucClusterName --resource-group $NucResourceGroup --query "{name:name, connectivity:connectivityStatus, lastConnectivity:lastConnectivityTime, distribution:distribution}" -o table

# Check ThinkStation cluster
az connectedk8s show --name $ThinkClusterName --resource-group $ThinkResourceGroup --query "{name:name, connectivity:connectivityStatus, lastConnectivity:lastConnectivityTime, distribution:distribution}" -o table
```

> Both should show `connectivityStatus: Connected`. If the NUC shows `Expired` or `Offline`, the machine may be powered off or Arc agents are unhealthy.

## Step 0a: Open Arc Proxy to NUC

Use `az connectedk8s proxy` to tunnel kubectl commands to the NUC through Azure Arc. Open a **new terminal window** and run:

```powershell
az connectedk8s proxy --name $NucClusterName --resource-group $NucResourceGroup
```

> This blocks the terminal — keep it running. In a **separate terminal**, set the kubeconfig context to use the proxy:

```powershell
$env:HTTPS_PROXY = "http://localhost:47011"
# kubectl commands now target the NUC cluster
kubectl get nodes
```

> **Tip**: Use separate terminals for NUC (proxied) and ThinkStation (direct) kubectl commands. Unsetting `$env:HTTPS_PROXY` switches back to the ThinkStation context.

## Step 0b: Open Arc Proxy to ThinkStation

Use `az connectedk8s proxy` to tunnel kubectl commands to the ThinkStation through Azure Arc. Open a **new terminal window** and run:

```powershell
az connectedk8s proxy --name $ThinkClusterName --resource-group $ThinkResourceGroup
```

> This blocks the terminal — keep it running. In a **separate terminal**, set the kubeconfig context to use the proxy:

```powershell
$env:HTTPS_PROXY = "http://localhost:47012"
# kubectl commands now target the ThinkStation cluster
kubectl get nodes
```

> ThinkStation steps (Steps 12-14) run in this proxied session.

---

# NUC-Side Checks (run in terminal with HTTPS_PROXY set to Arc proxy)

## Step 1: Discover Dataflow API Resources

```powershell
kubectl api-resources | Select-String -Pattern "dataflow"
```

## Step 2: List All Dataflows

```powershell
kubectl get dataflow -n azure-iot-operations
```

## Step 3: Get Detailed Dataflow Status

```powershell
kubectl get dataflow nuc-to-thinkstation -n azure-iot-operations -o yaml
```

## Step 4: List Dataflow Endpoints

```powershell
kubectl get dataflowendpoint -n azure-iot-operations
```

## Step 5: Inspect Target Endpoint

```powershell
kubectl get dataflowendpoint thinkstation -n azure-iot-operations -o yaml
```

## Step 6: Check Dataflow Pod Health

```powershell
kubectl get pods -n azure-iot-operations | Select-String -Pattern "dataflow"
```

## Step 7: Check Dataflow Pod Logs

```powershell
# Last 100 lines
kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=100

# Follow logs in real time (Ctrl+C to stop)
kubectl logs -n azure-iot-operations -l app=aio-dataflow -f
```

## Step 8: Verify Source Messages on Local Broker

> **Note**: `mosquitto_sub` cannot run through the Arc proxy. Use `kubectl exec` to run it inside a pod on the NUC:

```powershell
# Find a pod that has mosquitto tools, or use a debug pod:
kubectl run mqtt-debug --image=eclipse-mosquitto:2 --restart=Never --command -- mosquitto_sub -h localhost -p 1883 -t "factory/#" -C 5
kubectl logs mqtt-debug --follow
kubectl delete pod mqtt-debug
```

## Step 9: Verify Public Listener Service

```powershell
kubectl get service publiclistener -n azure-iot-operations
# EXTERNAL-IP should not be <pending>
```

## Step 10: Check Simulator Pod

```powershell
kubectl get pods -l app=edgemqttsim -n default
kubectl logs -l app=edgemqttsim -n default --tail=50
```

## Step 11: Check Overall AIO Health

```powershell
# All pods should be Running or Completed
kubectl get pods -n azure-iot-operations

# Show only unhealthy pods
kubectl get pods -n azure-iot-operations | Select-String -Pattern "Running|Completed" -NotMatch
```

---

# ThinkStation-Side Checks (run locally in elevated PowerShell)

## Step 12: Verify Messages Arriving from NUC

Confirm the NUC's relayed messages are landing in the ThinkStation broker:

```powershell
# Via AKS Edge Essentials:
Invoke-AksEdgeNodeCommand -NodeType Linux -command "mosquitto_sub -h localhost -p 1883 -t 'nuc/factory/#' -C 5"
```

> If no messages appear within 30 seconds, the NUC dataflow or Tailscale tunnel may be down.

## Step 13: Verify ThinkStation Public Listener

```powershell
kubectl get service publiclistener -n azure-iot-operations
# EXTERNAL-IP should match the AKS EE virtual IP
```

## Step 14: Verify Port Forwarding (Windows Host)

Check that `netsh portproxy` is forwarding Tailscale traffic to the AKS EE broker:

```powershell
netsh interface portproxy show all
# Should show 0.0.0.0:1883 -> <AKS EE LoadBalancer IP>:1883
```

If missing, re-create:

```powershell
$lbIP = kubectl get service publiclistener -n azure-iot-operations -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1883 connectaddress=$lbIP connectport=1883
```

---

# Cross-Machine Checks (run from ThinkStation)

## Step 15: Verify Arc Agent Health on Both Clusters

Check that Arc agents are running and recently connected:

```powershell
# Detailed NUC cluster status
az connectedk8s show --name $NucClusterName --resource-group $NucResourceGroup -o table

# Detailed ThinkStation cluster status
az connectedk8s show --name $ThinkClusterName --resource-group $ThinkResourceGroup -o table
```

## Step 16: Verify AIO Extensions on Both Clusters

```powershell
# NUC extensions
az k8s-extension list --cluster-name $NucClusterName --resource-group $NucResourceGroup --cluster-type connectedClusters -o table

# ThinkStation extensions
az k8s-extension list --cluster-name $ThinkClusterName --resource-group $ThinkResourceGroup --cluster-type connectedClusters -o table
```

> Both should show `microsoft.iotoperations` with `provisioningState: Succeeded`.