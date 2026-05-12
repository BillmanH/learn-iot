# lerobot-follower

Subscribes to joint position messages forwarded by an Azure IoT Operations (AIO)
dataflow endpoint and commands an SO101 follower arm connected via USB (Linux serial port).

Runs as a local Linux Python application using UV. No container, no Kubernetes pod.

---

## Architecture

```
SO101 Leader (USB)
      |
lerobot-leader (this machine or NUC)
      |  publishes to AIO broker
      v
AIO MQTT Broker  -->  [AIO Dataflow endpoint]  -->  Local Mosquitto (this machine)
                                                            |
                                                     lerobot-follower (this script)
                                                            |
                                                     SO101 Follower (USB)
```

The AIO dataflow forwards messages from the leader topic to the local Mosquitto
broker running on the Linux machine. The follower script subscribes to that local
broker and commands the arm in real time.

---

## Prerequisites

- Ubuntu 22.04 / Debian 12 or similar Linux host
- Python 3.10 or 3.11
- [UV](https://docs.astral.sh/uv/getting-started/installation/) installed
- Mosquitto installed and running locally:
  ```bash
  sudo apt install mosquitto mosquitto-clients
  sudo systemctl enable --now mosquitto
  ```
- User added to `dialout` group for serial port access (log out and back in after):
  ```bash
  sudo usermod -aG dialout $USER
  ```
- AIO dataflow endpoint configured to publish to this machine (see AIO Dataflow Setup below)
- `kubectl` configured to reach the cluster (for verifying the dataflow)

---

## AIO Dataflow Setup

Before running the follower, create an AIO dataflow endpoint that forwards leader
joint positions to the local Mosquitto broker on this machine.

1. In the AIO portal (or via ARM template), create a **Kafka/MQTT dataflow endpoint**
   pointing to this machine's IP on port 1883 with no authentication.

2. Create a dataflow that routes:
   - **Source**: AIO broker topic `robot/leader/joint_positions`
   - **Destination**: the external endpoint above, same topic

3. Verify messages are arriving:
   ```bash
   # On the Linux machine, subscribe via local Mosquitto
   mosquitto_sub -h localhost -p 1883 -t "robot/leader/joint_positions"
   ```
   You should see JSON messages with joint positions when the leader is running.

---

## First-Time Setup

### 1. Find the follower arm serial port

Plug in the USB cable for the SO101 follower arm, then run:
```bash
bash scripts/01_find_serial_port.sh
```

Or manually:
```bash
# List ports before plugging in
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

# Plug in the arm, then list again — the new entry is the arm
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
```

Common port names:
- `/dev/ttyACM0` — STM32 / Arduino-based controllers
- `/dev/ttyUSB0` — CH340 / CP2102 USB-serial chips

See [scripts/01_find_serial_port.sh](scripts/01_find_serial_port.sh) for an automated helper.

### 2. Edit the config file

```bash
cd modules/lerobot-follower
# Edit local_config.yaml
```

Set at minimum:
```yaml
follower_port: "/dev/ttyACM0"  # your serial port
mqtt_broker: "localhost"        # local Mosquitto
```

### 3. Install dependencies

```bash
cd modules/lerobot-follower

# Step 1: install feetech-servo-sdk without dependencies (avoids platform conflicts)
uv pip install feetech-servo-sdk==1.0.0 --no-deps

# Step 2: install everything else
uv sync
```

### 4. One-time motor setup (new motors only)

Only needed if the motors haven't been ID-configured before. Skip if the arm was
previously built and calibrated.

```bash
uv run python scripts/02_setup_motors_follower.py
```

### 5. Calibrate the arm

Run once before first use, and any time the arm is reassembled or its zero position drifts.

```bash
uv run python scripts/03_calibrate_follower.py
```

Follow the prompts:
1. Move the arm to the **middle** of its range, press ENTER
2. Move all joints through their **full range**, press ENTER to stop recording

The calibration is saved to `calibration/<follower_id>.json`.

### 6. Verify calibration

```bash
uv run python scripts/04_check_calibration.py
```

Review the joint values printed. Re-run after manually moving the arm to confirm
positions update correctly.

---

## Running the Application

```bash
cd modules/lerobot-follower
uv run python app.py
```

Output:
```
============================================================
lerobot-follower - AIO MQTT -> SO101 Follower Arm (local Windows)
  Follower port  : COM4
  Follower ID    : my_awesome_follower_arm
  Calibration    : ./calibration
  MQTT broker    : localhost:1883
  Topic          : robot/leader/joint_positions
============================================================

[...] Connecting to follower arm on COM4 ...
[OK] Follower arm connected

[...] Connecting to MQTT broker localhost:1883 ...
[OK] Connected to MQTT broker at localhost:1883
[OK] Subscribed to: robot/leader/joint_positions

[OK] Waiting for joint position messages. Press Ctrl+C to stop.
```

Press `Ctrl+C` to stop.

---

## File Structure

```
modules/lerobot-follower/
  app.py                          # Main loop: receive MQTT -> command follower arm
  local_config.yaml               # Config: COM port, broker, topic
  pyproject.toml                  # UV project definition
  README.md                       # This file
  scripts/
    01_find_com_port.md           # Instructions to find COM port
    02_setup_motors_follower.py   # One-time motor ID setup
    03_calibrate_follower.py      # Interactive calibration
    04_check_calibration.py       # Verify calibration
  calibration/
    my_awesome_follower_arm.json  # Generated by 03_calibrate_follower.py

# Shared source (used by both leader and follower):
modules/lerobot-src/
  lerobot_edge/                   # Vendored from BillmanH/lerobot@local_nuc
  pyproject.toml
```

---

## Refreshing the lerobot_edge Source

The shared source lives in `modules/lerobot-src/` (used by both leader and follower).
To pull the latest from the fork, run from the **repo root**:

```powershell
cd modules\lerobot-src
git clone --no-local --filter=blob:none --sparse -b local_nuc https://github.com/BillmanH/lerobot.git _tmp
cd _tmp ; git sparse-checkout set --skip-checks lerobot-edge/src
Remove-Item -Recurse -Force ..\lerobot-src\lerobot_edge
Copy-Item -Recurse -Force lerobot-edge\src\lerobot_edge ..\lerobot-src\lerobot_edge
cd .. ; Remove-Item -Recurse -Force _tmp
```

---

## Troubleshooting

**`[ERROR] Calibration file not found`**
Run `uv run python scripts/03_calibrate_follower.py`

**`[ERROR] Failed to connect to follower arm`**
- Check Device Manager for the correct COM port
- Make sure no other serial app (PuTTY, Arduino IDE) has the port open
- Try unplugging and replugging the USB cable

**`[ERROR] MQTT connect failed`**
- Verify Mosquitto is running: `Get-Service mosquitto` (or check Services)
- Verify `mqtt_broker` in `local_config.yaml` is correct
- Confirm the AIO dataflow endpoint is publishing to this machine's IP and port 1883

**No messages received (arm not moving)**
- Verify the AIO dataflow is active: `kubectl get dataflow -n azure-iot-operations`
- Subscribe to the local broker directly to confirm messages arrive:
  `mosquitto_sub -h localhost -p 1883 -t "robot/leader/joint_positions"`
- Check the leader is running and publishing

**`feetech-servo-sdk` install error**
Always install with `--no-deps`:
```powershell
uv pip install feetech-servo-sdk==1.0.0 --no-deps
```
