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

> **Travel note**: Steps are organized so everything at home is done first, then everything at the office in a single trip. AIO portal steps (creating listeners, endpoints, dataflows) are browser-based and can be done from anywhere — so the NUC's dataflow configuration is done from the office after you have the ThinkStation's Tailscale IP.

---

## Part 1 — At Home (NUC)

The only steps that require being home are SSH commands on the NUC. Do these three things, then you're done at home.

### Step 1: Set Kernel Parameters

Switch the repo to the dev branch first:
```bash
cd ~/learn-iothub && git fetch && git checkout dev && git pull
```

Then run the kernel params script:
```bash
chmod +x ~/learn-iothub/arc_build_linux/set_kernel_params.sh
~/learn-iothub/arc_build_linux/set_kernel_params.sh
```

### Step 2: Install Tailscale and Record NUC IP

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

> Your NUC's Tailscale IP is always visible at https://login.tailscale.com/admin/machines — no need to write it down. You can look it up from the ThinkStation at the office.

### Step 3: Create MQTT Public Listener on NUC

The manifest is already in the repo at `operations/publiclistener.yaml`. Apply it:

```bash
cd ~/learn-iothub
kubectl apply -f operations/publiclistener.yaml
```

Verify the LoadBalancer service is up and has an EXTERNAL-IP:
```bash
kubectl get service publiclistener -n azure-iot-operations
# Wait until EXTERNAL-IP is assigned (not <pending>)
```

> The NUC's EXTERNAL-IP is its LAN IP with port 1883 forwarded, reachable over Tailscale from the office.

**That's everything at home.** Leave the NUC running — K3s and AIO will stay up while you travel.

---

## Part 2 — At the Office (ThinkStation)

Everything from here is done in a single office session. The AIO portal steps for the NUC (dataflow config) are done here too, since the portal is browser-based and controls both clusters from anywhere.

### Step 0: Load the AKS Edge PowerShell Module

> **CRITICAL**: The `AksEdge` module has a `#Requires -RunAsAdministrator` directive. Every PowerShell session used in Part 2 **must be launched with "Run as Administrator"** — right-click the PowerShell icon and choose **Run as Administrator**, or from Windows Terminal use the dropdown → PowerShell → Run as Administrator. A non-elevated session will fail with `ScriptRequiresElevation`.

With an elevated session, import the module:

```powershell
Import-Module AksEdge

# Confirm the command is available
Get-Command Invoke-AksEdgeNodeCommand
```

> **Tip**: Add `Import-Module AksEdge` to your Administrator PowerShell profile so it loads automatically:
> ```powershell
> Add-Content $PROFILE "`nImport-Module AksEdge"
> ```

**Assumptions for Part 2**: AKS Edge Essentials is already installed and the `bel-aio-work-cluster` cluster is already running with Azure IoT Operations deployed. The steps below pick up from that state — no fresh AKS EE or AIO deployment is needed.

### Step 1: Set Kernel Parameters

Open PowerShell as Administrator on the ThinkStation and run these against the AKS EE Linux VM:

```powershell
Invoke-AksEdgeNodeCommand -NodeType Linux -command "sudo tee -a /etc/sysctl.conf << 'EOF'
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
fs.file-max = 100000
EOF"

Invoke-AksEdgeNodeCommand -NodeType Linux -command "sudo sysctl -p"
Invoke-AksEdgeNodeCommand -NodeType Linux -command "sudo systemctl restart k3s"
```

### Step 2: Install Tailscale and Record ThinkStation IP

Tailscale installs on the **Windows host**, not inside the AKS EE Linux VM:

```powershell
# Install Tailscale on Windows
winget install tailscale.tailscale
# Sign in via the system tray icon using the same Tailscale account as the NUC

# Record the Windows Tailscale IP
tailscale ip -4  # e.g. 100.x.x.20
```

> Both IPs are also visible at https://login.tailscale.com/admin/machines.

### Step 3: Create MQTT Public Listener on ThinkStation

The same manifest in the repo works for both clusters. Apply it from Windows PowerShell:

```powershell
cd C:\path\to\learn-iothub  # wherever you cloned the repo on the ThinkStation
kubectl apply -f operations\publiclistener.yaml
```

Verify the LoadBalancer service is up and get its IP:
```powershell
kubectl get service publiclistener -n azure-iot-operations
# EXTERNAL-IP will be a virtual IP from the AKS EE service range (e.g. 192.168.x.x)
# Wait until it is no longer <pending>
```

### Step 4: Set Up Port Forwarding on ThinkStation

The NUC cannot reach the AKS EE virtual IP directly. Windows forwards inbound traffic from the Tailscale interface to the broker:

```powershell
# Pull the LoadBalancer IP directly from the service
$lbIP = kubectl get service publiclistener -n azure-iot-operations -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Write-Host "LoadBalancer IP: $lbIP"

# Forward Tailscale port 1883 to the AKS EE broker
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1883 connectaddress=$lbIP connectport=1883

# Open Windows Firewall for inbound MQTT
netsh advfirewall firewall add rule name="AIO-MQTT-1883" dir=in action=allow protocol=TCP localport=1883
```

> This rule persists across reboots. Verify with `netsh interface portproxy show all`. Only needs to be re-run if the AKS EE LoadBalancer IP changes (it typically doesn't).

### Step 5: Configure NUC DataFlow → ThinkStation

The NUC's DataFlow reads from its own local broker and publishes to the ThinkStation's public listener. This is done entirely in the AIO portal — no SSH needed.

**Create the DataFlow endpoint** — in the AIO portal, go to the `iot-ops-cluster` (NUC) instance:

1. **Data flow endpoints** → Custom MQTT Broker → Create
   - Name: `thinkstation`
   - Host: `<THINKSTATION_TAILSCALE_IP>:1883`  _(the IP recorded in Step 2)_
   - Authentication: None
2. Apply and wait for creation

**Create the DataFlow** — still on the `iot-ops-cluster` (NUC) instance:

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

### Step 6: Verify NUC→ThinkStation Relay

```powershell
# Subscribe with mosquitto inside the AKS EE VM:
Invoke-AksEdgeNodeCommand -NodeType Linux -command "mosquitto_sub -h localhost -p 1883 -t 'nuc/factory/#'"

# Or use mqttui for a visual view:
Invoke-AksEdgeNodeCommand -NodeType Linux -command "mqttui --broker mqtt://localhost:1883"
# Navigate to nuc/factory/ in the left pane
```

You should see the NUC's factory messages arriving in the ThinkStation's broker. If nothing appears within 30 seconds, check the DataFlow status in the AIO portal (`iot-ops-cluster` → Data flows → `nuc-to-thinkstation`).

### Step 7: Assign Event Hubs Permissions

1. In Azure Portal, go to your Event Hubs namespace
2. Access Control (IAM) → Add role assignment
   - Role: `Azure Event Hubs Data Sender`
   - Member: The managed identity of the `bel-aio-work-cluster` AIO instance  
     (same name as the Arc extension: `bel-aio-work-cluster-aio`)

### Step 8: Create Event Hubs DataFlow Endpoint on ThinkStation

1. In AIO portal, go to `bel-aio-work-cluster` instance
2. Data flow endpoints → Azure Event Hubs → Create
   - Name: `cloud-eventhubs`
   - Host: Search for your Event Hubs namespace by name
   - Authentication: System assigned managed identity
3. Apply and wait

### Step 9: Create ThinkStation DataFlow → Azure

This creates the pipeline: **ThinkStation MQTT → Azure Event Hubs**.

1. Data flows → Create new data flow
2. **Source** — Message broker
   - Data flow endpoint: `default` (ThinkStation's own local broker)
   - Topic: `nuc/factory/#`  _(matches the destination topic from Step 5)_
   - Message schema: Upload — sample a message first:
     ```powershell
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

### Step 10: Validate End-to-End

1. **Confirm edgemqttsim is running on the NUC** (SSH or via Tailscale from the ThinkStation):
   ```bash
   kubectl get pods -l app=edgemqttsim -n default
   kubectl logs -l app=edgemqttsim -f
   ```

2. **Confirm factory messages are on the NUC broker:**
   ```bash
   mosquitto_sub -h localhost -p 1883 -t "factory/#"
   # Should see edgemqttsim messages flowing
   ```

3. **Confirm NUC→ThinkStation relay is working:**
   ```powershell
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

**At Home (NUC):**
- [ ] Kernel parameters set on NUC (`set_kernel_params.sh` run successfully)
- [ ] Tailscale installed on NUC (IP visible at https://login.tailscale.com/admin/machines)
- [ ] MQTT public listener `publiclistener` created on NUC (`kubectl apply -f operations/publiclistener.yaml`)

**At the Office (ThinkStation):**
- [ ] Kernel parameters set on ThinkStation (via `Invoke-AksEdgeNodeCommand`)
- [ ] Tailscale installed on ThinkStation (IP visible at https://login.tailscale.com/admin/machines)
- [ ] MQTT public listener `publiclistener` created on ThinkStation (`kubectl apply -f operations\publiclistener.yaml`)
- [ ] `netsh portproxy` rule set up (ThinkStation Tailscale → AKS EE LoadBalancer)
- [ ] Windows Firewall rule `AIO-MQTT-1883` created
- [ ] DataFlow endpoint `thinkstation` created on NUC (host = ThinkStation Tailscale IP:1883, via AIO portal)
- [ ] DataFlow `nuc-to-thinkstation` deployed and running on NUC
- [ ] Verified NUC messages arriving in ThinkStation broker (`nuc/factory/#`)
- [ ] Event Hubs role assignment for ThinkStation AIO managed identity
- [ ] DataFlow endpoint `cloud-eventhubs` created on ThinkStation
- [ ] DataFlow `thinkstation-to-cloud` deployed and running on ThinkStation
- [ ] End-to-end telemetry verified in Azure Event Hubs metrics

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
| AIO not yet deployed | Both already have AIO deployed and running | Skip deploy-aio steps |
| AKS EE not installed | AKS EE already installed on ThinkStation | Skip AKS EE installation; just `Import-Module AksEdge` in elevated session |
| Kernel params unknown | Likely unset | Set via `Invoke-AksEdgeNodeCommand` on ThinkStation |
