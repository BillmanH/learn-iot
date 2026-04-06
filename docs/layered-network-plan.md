# Layered AIO Network Plan: NUC (Level 1) → ThinkStation (DMZ) → Azure

## Reference
- [AIO Layered Network Overview](https://github.com/Azure-Samples/explore-iot-operations/blob/main/samples/layered-networking/aio-layered-network.md)
- [Asset Telemetry (MQTT chaining)](https://github.com/Azure-Samples/explore-iot-operations/blob/main/samples/layered-networking/asset-telemetry.md)
- [Arc Enable Clusters](https://github.com/Azure-Samples/explore-iot-operations/blob/main/samples/layered-networking/arc-enable-clusters.md)

---

## Your Setup vs. the Reference Architecture

| Purdue Level | Reference Doc Machine | Your Machine | Cluster Name | Resource Group |
|---|---|---|---|---|
| Level 1 / Level 2 | `level2` (192.168.102.10) | **NUC (home)** | `iot-ops-cluster` | `IoT-Operations` (westus2) |
| Level 3 / Level 4 | `level3` + `level4` | **ThinkStation (work)** — Windows + AKS Edge Essentials | `bel-aio-work-cluster` | `IoT-Operations-Work-Edge-bel-aio` (eastus) |
| Jump Box | 192.168.0.50 | **Your Windows dev machine** | — | — |

**2-node simplification**: Both machines have direct internet access, so there is no need for Envoy Proxy or CoreDNS gateway infrastructure. The only thing needed is a direct MQTT path from the NUC's broker to the ThinkStation's broker, then from the ThinkStation up to Azure.

The Purdue-model concept being implemented here is: **each level's MQTT broker accepts messages from the level below it, and relays (potentially with transformation) to the level above**. Envoy/CoreDNS in the original doc exists only to give internet-isolated machines a path to Azure Arc — you don't need it.

---

## Pre-Condition: Cross-Network IP Reachability

The NUC (home `10.186.247.76`) and ThinkStation (work) are on different physical networks and cannot reach each other's LAN IPs directly. You need a stable IP that each machine can use to reach the other.

**Recommended: Tailscale** — free, gives each machine a stable `100.x.x.x` IP that works across any network.

### On NUC (Ubuntu Server — SSH in and run):
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4  # record this, e.g. 100.x.x.10
```

### On ThinkStation (Windows — run in PowerShell as Administrator):
Tailscale installs on the **Windows host**, not inside the AKS EE Linux VM. AKS EE's LoadBalancer IPs are internal virtual IPs, so Windows needs to forward port 1883 to the broker after Tailscale is running.

```powershell
# Install Tailscale on Windows
winget install tailscale.tailscale
# Sign in via the system tray icon, using the same account as the NUC

# Record the Windows Tailscale IP
tailscale ip -4  # e.g. 100.x.x.20

# After Phase 2 (creating the public listener), get the AKS EE LoadBalancer IP:
$lbIP = kubectl get service publiclistener -n azure-iot-operations -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Write-Host "LoadBalancer IP: $lbIP"

# Forward Windows Tailscale interface port 1883 to the AKS EE broker
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1883 connectaddress=$lbIP connectport=1883

# Open Windows Firewall for inbound MQTT
netsh advfirewall firewall add rule name="AIO-MQTT-1883" dir=in action=allow protocol=TCP localport=1883
```

> The NUC's DataFlow endpoint will use the **Windows Tailscale IP** (`100.x.x.20`) on port 1883. Windows forwards that to the AKS EE broker automatically.

> The `netsh portproxy` rule persists across reboots but must be re-run if the AKS EE LoadBalancer IP changes (it typically doesn't). Verify with `netsh interface portproxy show all`.

---

## Phase 1 — Set Kernel Parameters (Both Machines)

Required to prevent Arc connection timeouts.

### On NUC (SSH in and run):

Switch the repo to the dev branch first:
```bash
cd ~/learn-iothub && git fetch && git checkout dev && git pull
```

Then set the kernel parameters (single line):
```bash
printf '\nfs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=524288\nfs.file-max = 100000\n' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p > /dev/null && sudo systemctl restart k3s
```

### On ThinkStation (PowerShell as Administrator — runs inside the AKS EE Linux VM):
```powershell
Invoke-AksEdgeNodeCommand -NodeType Linux -command "sudo tee -a /etc/sysctl.conf << 'EOF'
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
fs.file-max = 100000
EOF"

Invoke-AksEdgeNodeCommand -NodeType Linux -command "sudo sysctl -p"
Invoke-AksEdgeNodeCommand -NodeType Linux -command "sudo systemctl restart k3s"
```

---

## Phase 2 — Create MQTT Public Listeners on Both Clusters

Each AIO MQTT broker needs a `LoadBalancer` listener on port 1883 so that the other cluster can connect to it as a remote MQTT endpoint. By default the AIO MQTT broker only listens internally within the cluster.

**Do this in the AIO portal at https://iotoperations.azure.com/**

### On ThinkStation (`bel-aio-work-cluster`) — do this first
1. Open the `bel-aio-work-cluster` instance
2. Components → MQTT Broker → Create new listener
   - Name: `publiclistener`
   - Service name: (leave blank)
   - Port: `1883`, Authentication: None, Authorization: None, Protocol: MQTT, No TLS
3. Create the listener and wait for it to deploy

Verify the LoadBalancer has an external IP (run from Windows PowerShell on the ThinkStation):
```powershell
kubectl get service publiclistener -n azure-iot-operations
# EXTERNAL-IP will be a virtual IP from the AKS EE service range (e.g. 192.168.x.x)
# This is the IP you'll use in the netsh portproxy command from the Pre-Condition section
```

> The `EXTERNAL-IP` is an internal AKS EE virtual IP. The NUC cannot reach it directly.
> Use the **Windows Tailscale IP** in the DataFlow endpoint config and rely on the `netsh portproxy` rule to forward traffic from there to this IP.

### On NUC (`iot-ops-cluster`)
Same steps — this listener is needed so the ThinkStation can optionally inspect or subscribe to the NUC's broker directly, and for future reverse-flow scenarios.

1. Open the `iot-ops-cluster` instance
2. Components → MQTT Broker → Create new listener
   - Name: `publiclistener`
   - Port: `1883`, Authentication: None, Authorization: None, Protocol: MQTT, No TLS

---

## Phase 3 — Configure NUC DataFlow: Factory MQTT → ThinkStation MQTT

This is the core of the layered setup. The NUC's DataFlow reads from its own local MQTT broker and **publishes to the ThinkStation's public listener** — making the NUC's outgoing stream the ThinkStation's incoming stream.

### Step 1: Create a DataFlow Endpoint on the NUC pointing to the ThinkStation

In the AIO portal, go to the `iot-ops-cluster` (NUC) instance:

1. **Data flow endpoints** → Custom MQTT Broker → Create
   - Name: `thinkstation`
   - Host: `<THINKSTATION_TAILSCALE_IP>:1883`
   - Authentication: None
2. Apply and wait for creation

### Step 2: Create the DataFlow on the NUC

1. **Data flows** → Create new data flow
2. **Source** — Select source → Message broker
   - Data flow endpoint: `default` (the NUC's own local broker)
   - Topic: `factory/#`  _(or whatever topic your edgemqttsim publishes to)_
3. **Destination** — Select data flow endpoint → `thinkstation`
   - Topic: `nuc/factory/#`  _(this is where messages land in the ThinkStation's broker)_
4. **Transform** (optional) — Add property:
   - Key: `source-node`, Value: `home-nuc`
5. Edit the pipeline name:
   - Name: `nuc-to-thinkstation`, Enable data flow: checked
6. Save and wait for deployment

Verify from your ThinkStation (Windows PowerShell):
```powershell
# Using mqttui inside the AKS EE Linux VM:
Invoke-AksEdgeNodeCommand -NodeType Linux -command "mqttui --broker mqtt://localhost:1883"
# Navigate to nuc/factory/ in the left pane

# Or subscribe with mosquitto:
Invoke-AksEdgeNodeCommand -NodeType Linux -command "mosquitto_sub -h localhost -p 1883 -t 'nuc/factory/#'"
```

You should see the NUC's factory messages arriving in the ThinkStation's broker under the `nuc/factory/#` topic.

---

## Phase 4 — Configure ThinkStation DataFlow: MQTT → Azure

This creates the pipeline: **ThinkStation MQTT → Azure Event Hubs** (or Fabric Event Stream).

### Step 1: Assign Event Hubs Permissions
1. In Azure Portal, go to your Event Hubs namespace
2. Access Control (IAM) → Add role assignment
   - Role: `Azure Event Hubs Data Sender`
   - Member: The managed identity of the `bel-aio-work-cluster` AIO instance  
     (same name as the Arc extension: `bel-aio-work-cluster-aio`)

### Step 2: Create an Event Hubs DataFlow Endpoint on the ThinkStation
1. In AIO portal, go to `bel-aio-work-cluster` instance
2. Data flow endpoints → Azure Event Hubs → Create
   - Name: `cloud-eventhubs`
   - Host: Search for your Event Hubs namespace by name
   - Authentication: System assigned managed identity
3. Apply and wait

### Step 3: Create the DataFlow on the ThinkStation
1. Data flows → Create new data flow
2. **Source** — Message broker
   - Data flow endpoint: `default` (ThinkStation's own local broker)
   - Topic: `nuc/factory/#`  _(matches the destination topic you set in Phase 3)_
   - Message schema: Upload — sample a message first:
     ```powershell
     # On ThinkStation Windows PowerShell:
     Invoke-AksEdgeNodeCommand -NodeType Linux -command "mosquitto_sub -h localhost -p 1883 -t 'nuc/factory/#' -C 1"
     # Copy the output, paste into https://azure-samples.github.io/explore-iot-operations/schema-gen-helper/
     # Set all fields nullable, download as thinkstation-inschema.json
     ```
3. **Destination** — `cloud-eventhubs`
   - Topic: `<your-event-hub-name>` (the Event Hub name, not the namespace)
4. **Transform** (optional) — Add property:
   - Key: `relay-node`, Value: `thinkstation-work`
5. Pipeline name: `thinkstation-to-cloud`, Enable data flow: checked
6. Save and wait for deployment

> **Using Fabric instead of Event Hubs?** Use a Kafka endpoint with `SystemAssignedManagedIdentity` auth — no connection strings needed. See `fabric_setup/` docs in this repo.

---

## Phase 5 — Validate End-to-End

1. **Confirm edgemqttsim is running on the NUC:**
   ```bash
   # SSH to NUC
   kubectl get pods -l app=edgemqttsim -n default
   kubectl logs -l app=edgemqttsim -f
   ```

2. **Confirm factory messages are on the NUC broker:**
   ```bash
   # SSH to NUC (or from Windows dev machine via Tailscale)
   mosquitto_sub -h localhost -p 1883 -t "factory/#"
   # Should see edgemqttsim messages flowing
   ```

3. **Confirm NUC→ThinkStation relay is working:**
   ```powershell
   # On ThinkStation Windows PowerShell:
   # Using mqttui inside the AKS EE VM:
   Invoke-AksEdgeNodeCommand -NodeType Linux -command "mqttui --broker mqtt://localhost:1883"

   # Or subscribe with mosquitto inside the VM:
   Invoke-AksEdgeNodeCommand -NodeType Linux -command "mosquitto_sub -h localhost -p 1883 -t 'nuc/factory/#'"
   ```
   You should see NUC factory messages arriving ~instantly.

4. **Check DataFlow health** in AIO portal:
   - `iot-ops-cluster` → Data flows → `nuc-to-thinkstation` → should show `Running`
   - `bel-aio-work-cluster` → Data flows → `thinkstation-to-cloud` → should show `Running`

5. **Check Azure Event Hubs metrics:**
   - Azure Portal → Event Hubs namespace → Metrics → Incoming Messages (Sum)
   - Messages should appear within 1–2 minutes of starting edgemqttsim

---

## Architecture Diagram (Your Setup)

```
[NUC - Home - Ubuntu]            [ThinkStation - Work - Windows]         [Azure]
  K3s + AIO                        AKS Edge Essentials + AIO
  edgemqttsim                       Linux VM (internal)
  MQTT Broker (:1883)               AIO MQTT Broker (virtual IP)
  DataFlow: factory/# ──────────►  Windows Tailscale IP:1883          Event Hubs
    (via Tailscale 100.x.x.x)       netsh portproxy ↓          ─────► / Fabric RTI
                                    AKS EE broker (nuc/factory/#)
                                    DataFlow → Azure ──────────▲
```

Data context added at each hop:
- **NUC DataFlow** adds `source-node: home-nuc` before forwarding
- **ThinkStation DataFlow** adds `relay-node: thinkstation-work` before pushing to Azure
- Azure receives the fully enriched message with context from both levels

---

## Checklist

- [ ] **Cross-network connectivity working** (Tailscale or equivalent)
- [ ] Record ThinkStation reachable IP from NUC: `___________________`
- [ ] **Kernel parameters set on NUC** (`/etc/sysctl.conf` + k3s restart)
- [ ] **Kernel parameters set on ThinkStation** (`/etc/sysctl.conf` + k3s restart)
- [ ] **MQTT public listener `publiclistener` created on ThinkStation** (port 1883)
- [ ] **MQTT public listener `publiclistener` created on NUC** (port 1883)
- [ ] **DataFlow endpoint `thinkstation` created on NUC** (host = ThinkStation reachable IP:1883)
- [ ] **DataFlow `nuc-to-thinkstation` deployed and running on NUC**
- [ ] **Verified NUC messages arriving in ThinkStation broker** (`nuc/factory/#`)
- [ ] **Event Hubs role assignment for ThinkStation AIO managed identity**
- [ ] **DataFlow endpoint `cloud-eventhubs` created on ThinkStation**
- [ ] **DataFlow `thinkstation-to-cloud` deployed and running on ThinkStation**
- [ ] **End-to-end telemetry verified in Azure Event Hubs metrics**

---

## Key Differences from the Reference Doc

| Doc Assumption | Your Reality | Result |
|---|---|---|
| 3 machines (L2, L3, L4) | 2 machines | ThinkStation = L3+L4 combined |
| Same LAN with VLANs | Different physical networks | Tailscale on both |
| Machines lack direct internet | Both have internet | **Envoy/CoreDNS not needed** |
| All machines run Linux | ThinkStation is Windows + AKS EE | Tailscale on Windows host; commands use `Invoke-AksEdgeNodeCommand` or PowerShell kubectl |
| Jump box for SSH access | Windows dev machine | Use kubectl contexts or PowerShell from Windows |
| Arc not yet connected | Both already Arc-connected | Skip arc-enable-clusters steps |
| AIO not yet deployed | Both already have AIO | Skip deploy-aio steps |
| Kernel params unknown | Likely unset | Set via `Invoke-AksEdgeNodeCommand` on ThinkStation |
