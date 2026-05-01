"""
lerobot-follower - AIO MQTT -> SO101 Follower Arm
Runs locally on Windows. Subscribes to a local MQTT broker that receives
joint position messages forwarded by an AIO dataflow endpoint, then commands
the SO101 follower arm over USB (COM port).

Architecture:
    AIO broker  -->  [AIO Dataflow]  -->  local Mosquitto (this machine)
                                               |
                                          lerobot-follower (this script)
                                               |
                                          SO101 Follower (USB)

Usage:
    uv run python app.py

Edit local_config.yaml before running:
    - follower_port: COM port of the follower arm (e.g. COM4)
    - mqtt_broker:   IP/hostname of the local Mosquitto broker (usually localhost)
"""

import json
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt
import yaml

# ---------------------------------------------------------------------------
# Configuration - loaded from local_config.yaml
# ---------------------------------------------------------------------------

def load_config() -> dict:
    config_path = Path(__file__).parent / "local_config.yaml"
    if not config_path.exists():
        print(f"[ERROR] Config file not found: {config_path}")
        print("  Copy local_config.yaml and edit it.")
        sys.exit(1)
    with open(config_path) as f:
        return yaml.safe_load(f)

_cfg = load_config()

FOLLOWER_PORT     = _cfg["follower_port"]
FOLLOWER_ID       = _cfg["follower_id"]
CALIBRATION_DIR   = _cfg["calibration_dir"]

MQTT_BROKER       = _cfg["mqtt_broker"]
MQTT_PORT         = int(_cfg["mqtt_port"])
MQTT_TOPIC        = _cfg["mqtt_topic"]
MQTT_CLIENT_ID    = _cfg["mqtt_client_id"]

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

_follower = None   # set in main() before callbacks run
_connected = False
_msg_count = 0

# ---------------------------------------------------------------------------
# MQTT callbacks
# ---------------------------------------------------------------------------

def on_connect(client, userdata, flags, reason_code, properties=None):
    global _connected
    rc = reason_code.value if hasattr(reason_code, "value") else reason_code
    if rc == 0:
        print(f"[OK] Connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
        client.subscribe(MQTT_TOPIC)
        print(f"[OK] Subscribed to: {MQTT_TOPIC}")
        _connected = True
    else:
        print(f"[ERROR] MQTT connect failed, code={rc}")
        _connected = False


def on_disconnect(client, userdata, reason_code, properties=None):
    global _connected
    _connected = False
    rc = reason_code.value if hasattr(reason_code, "value") else reason_code
    if rc != 0:
        print(f"[WARN] Unexpected disconnect, code={rc} - will reconnect")


def on_message(client, userdata, msg):
    global _msg_count
    try:
        payload = json.loads(msg.payload.decode())
    except Exception as e:
        print(f"[WARN] Failed to parse message: {e}")
        return

    joints = payload.get("joints")
    if not joints:
        print("[WARN] Message missing 'joints' field, skipping")
        return

    try:
        _follower.send_action(joints)
    except Exception as e:
        print(f"[ERROR] send_action failed: {e}")
        return

    _msg_count += 1
    if _msg_count % 100 == 0:
        print(f"[stats] messages received={_msg_count}  joints={list(joints.values())}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global _follower

    print("=" * 60)
    print("lerobot-follower - AIO MQTT -> SO101 Follower Arm (local Windows)")
    print(f"  Follower port  : {FOLLOWER_PORT}")
    print(f"  Follower ID    : {FOLLOWER_ID}")
    print(f"  Calibration    : {CALIBRATION_DIR}")
    print(f"  MQTT broker    : {MQTT_BROKER}:{MQTT_PORT}")
    print(f"  Topic          : {MQTT_TOPIC}")
    print("=" * 60)

    # --- lerobot_edge imports ---
    try:
        from lerobot_edge.robots.so101_follower import SO101Follower, SO101FollowerConfig
    except ImportError as e:
        print(f"[ERROR] Could not import lerobot_edge: {e}")
        print("  Run: uv sync")
        sys.exit(1)

    # Validate calibration file
    calib_path = Path(CALIBRATION_DIR) / f"{FOLLOWER_ID}.json"
    if not calib_path.exists():
        print(f"[ERROR] Calibration file not found: {calib_path}")
        print("  Run: uv run python scripts/03_calibrate_follower.py")
        sys.exit(1)

    # --- Connect follower arm ---
    print(f"\n[...] Connecting to follower arm on {FOLLOWER_PORT} ...")
    follower_config = SO101FollowerConfig(
        port=FOLLOWER_PORT,
        id=FOLLOWER_ID,
        calibration_dir=Path(CALIBRATION_DIR),
    )
    _follower = SO101Follower(follower_config)

    try:
        _follower.connect(calibrate=False)
        print("[OK] Follower arm connected")
    except Exception as e:
        print(f"[ERROR] Failed to connect to follower arm: {e}")
        print("  Check:")
        print(f"  1. Arm is plugged in and powered on")
        print(f"  2. follower_port={FOLLOWER_PORT} is correct (Device Manager -> Ports)")
        print(f"  3. No other process is using {FOLLOWER_PORT}")
        sys.exit(1)

    # --- Set up MQTT ---
    print(f"\n[...] Connecting to MQTT broker {MQTT_BROKER}:{MQTT_PORT} ...")
    client = mqtt.Client(
        client_id=MQTT_CLIENT_ID,
        protocol=mqtt.MQTTv5,
        transport="tcp",
    )
    client.on_connect    = on_connect
    client.on_disconnect = on_disconnect
    client.on_message    = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    try:
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()
    except Exception as e:
        print(f"[ERROR] MQTT connect failed: {e}")
        print("  Check:")
        print(f"  1. mqtt_broker={MQTT_BROKER} is reachable")
        print(f"  2. Mosquitto is running: Get-Service mosquitto")
        _follower.disconnect()
        sys.exit(1)

    # Wait for MQTT connection
    for _ in range(10):
        if _connected:
            break
        time.sleep(0.5)
    if not _connected:
        print("[ERROR] Timed out waiting for MQTT connection")
        client.loop_stop()
        _follower.disconnect()
        sys.exit(1)

    print("\n[OK] Waiting for joint position messages. Press Ctrl+C to stop.\n")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[...] Shutting down...")
    finally:
        client.loop_stop()
        client.disconnect()
        _follower.disconnect()
        print("[OK] Disconnected. Goodbye.")


if __name__ == "__main__":
    main()
