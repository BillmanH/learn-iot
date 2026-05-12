# LeRobot Leader / Follower — Azure IoT Operations

Teleoperation of an SO101 robot arm pair using Azure IoT Operations (AIO) as the
message relay. The **leader** arm (Windows) captures joint positions and publishes
them to the AIO MQTT broker. The **follower** arm (Linux) receives them via an AIO
dataflow and mirrors the motion in real time.

---

## Architecture

```
  WINDOWS (ThinkStation)                   AZURE IOT OPERATIONS (NUC / K3s)
  ─────────────────────────                ──────────────────────────────────────────
                                           ┌─────────────────────────────────────┐
  ┌──────────────┐   USB                   │                                     │
  │  SO101       │◄──────                  │  ┌──────────────────────────────┐   │
  │  Leader Arm  │                         │  │   AIO MQTT Broker            │   │
  └──────┬───────┘                         │  │   (port 1883, publiclistener) │   │
         │ joint positions (20 Hz)         │  └──────────────┬───────────────┘   │
         │                                 │                 │                    │
  ┌──────▼───────┐    MQTT publish         │  ┌──────────────▼───────────────┐   │
  │  lerobot-    │─────────────────────────►  │   AIO Dataflow Endpoint      │   │
  │  leader      │  robot/leader/          │  │   (forwards to follower LAN) │   │
  │  (app.py)    │  joint_positions        │  └──────────────┬───────────────┘   │
  └──────────────┘                         │                 │                    │
                                           └─────────────────┼────────────────────┘
                                                             │ MQTT forward
  LINUX (Follower machine)                                   │
  ─────────────────────────────────────────────────────────  │
                                           ┌─────────────────▼───────────────┐
                                           │  Local Mosquitto (port 1883)    │
                                           └─────────────────┬───────────────┘
                                                             │ subscribes
                                           ┌─────────────────▼───────────────┐
                                           │  lerobot-follower (app.py)      │
                                           └─────────────────┬───────────────┘
                                                             │ USB serial
                                           ┌─────────────────▼───────────────┐
                                           │  SO101 Follower Arm             │
                                           └─────────────────────────────────┘
```

**Key points:**
- The leader and follower never communicate directly — AIO is the relay
- The AIO broker is exposed unauthenticated on port 1883 via `publiclistener` (internal LAN only)
- An AIO dataflow forwards `robot/leader/joint_positions` to the follower machine's local Mosquitto
- Both scripts run as plain Python processes (UV), not containers

---

## Getting Started

### Step 1 — Apply the public MQTT listener (once per cluster)

Run from the Windows machine with `kubectl` pointed at the cluster:

```powershell
kubectl apply -f operations/publiclistener.yaml
kubectl get service publiclistener -n azure-iot-operations
```

Note the **EXTERNAL-IP** — this is the `mqtt_broker` address for the leader config.

---

### Step 2 — Set up the leader (Windows)

Full instructions: [modules/lerobot-leader/readme.md](modules/lerobot-leader/readme.md)

Quick summary:

```powershell
cd modules\lerobot-leader

# Install dependencies
uv pip install feetech-servo-sdk==1.0.0 --no-deps
uv sync

# Configure
# Edit local_config.yaml:
#   leader_port: "COM3"          <- Device Manager -> Ports (COM & LPT)
#   mqtt_broker: "192.168.0.x"  <- EXTERNAL-IP from Step 1

# One-time motor setup (new motors only)
uv run python scripts\02_setup_motors_leader.py

# Calibrate
uv run python scripts\03_calibrate_leader.py
```

---

### Step 3 — Set up the follower (Linux)

Full instructions: [modules/lerobot-follower/readme.md](modules/lerobot-follower/readme.md)

Quick summary:

```bash
# Install Mosquitto
sudo apt install mosquitto mosquitto-clients
sudo systemctl enable --now mosquitto

# Add user to dialout group (re-login after)
sudo usermod -aG dialout $USER

cd modules/lerobot-follower

# Install dependencies
uv pip install feetech-servo-sdk==1.0.0 --no-deps
uv sync

# Find the serial port
bash scripts/01_find_serial_port.sh

# Configure
# Edit local_config.yaml:
#   follower_port: "/dev/ttyACM0"   <- from script above
#   mqtt_broker: "localhost"

# One-time motor setup (new motors only)
uv run python scripts/02_setup_motors_follower.py

# Calibrate
uv run python scripts/03_calibrate_follower.py
```

---

### Step 4 — Create the AIO Dataflow

In the AIO portal, create a dataflow that forwards messages from the AIO broker to
the follower machine's local Mosquitto:

- **Source**: AIO broker, topic `robot/leader/joint_positions`
- **Destination**: MQTT endpoint pointing to the follower machine IP, port 1883
- **Authentication**: None (plain TCP, internal LAN)

Verify on the follower machine:

```bash
mosquitto_sub -h localhost -p 1883 -t "robot/leader/joint_positions"
```

You should see JSON messages when the leader is running.

---

### Step 5 — Run

On Windows (leader):
```powershell
cd modules\lerobot-leader
uv run python app.py
```

On Linux (follower):
```bash
cd modules/lerobot-follower
uv run python app.py
```

The follower arm should mirror the leader arm with ~20 Hz update rate.

---

## Module Reference

| Module | Host | Description |
|---|---|---|
| [modules/lerobot-leader](modules/lerobot-leader/readme.md) | Windows (ThinkStation) | Reads SO101 leader arm, publishes to AIO broker |
| [modules/lerobot-follower](modules/lerobot-follower/readme.md) | Linux | Subscribes from local Mosquitto, commands SO101 follower arm |

---

## Troubleshooting

| Topic | Document |
|---|---|
| AIO general issues | [docs/troubleshooting_aio.md](docs/troubleshooting_aio.md) |
| Internal networking / VLAN | [docs/internal_networking_troubleshooting.md](docs/internal_networking_troubleshooting.md) |
| Key Vault / secret sync | [docs/KEYVAULT_INTEGRATION.md](docs/KEYVAULT_INTEGRATION.md) |
| Verify secret management | [docs/VERIFY_SECRET_MANAGEMENT.md](docs/VERIFY_SECRET_MANAGEMENT.md) |
| Layered network plan | [docs/layered-network-plan.md](docs/layered-network-plan.md) |
| ONVIF connector auth bug | [issues/onvif_connector_bug.md](issues/onvif_connector_bug.md) |
| Tapo camera setup | [issues/home1-desk-tapo.md](issues/home1-desk-tapo.md) |

---

## Azure Resources

| Resource | Value |
|---|---|
| Subscription | `5c043aac-3d88-43d5-aec8-cd02ee6c914a` |
| Resource Group | `IoT-Operations` |
| Cluster | `iot-ops-cluster` |
| AIO Namespace | `azure-iot-operations` (K8s) |
| AIO Instance | `iot-operations-ns` |
| Broker public port | `1883` via `publiclistener` LoadBalancer |

**Useful kubectl commands:**

```bash
# Check broker listener is up
kubectl get service publiclistener -n azure-iot-operations

# Watch all AIO pods
kubectl get pods -n azure-iot-operations

# Tail follower-side dataflow logs
kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=50 -f
```
