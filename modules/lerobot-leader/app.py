"""
lerobot-leader - SO101 Leader Arm -> AIO MQTT Publisher
Runs locally on Windows. Reads joint positions from an SO101 leader arm
connected via USB (COM port) and publishes them to the AIO MQTT broker
via the publiclistener (port 1883, plain TCP, no auth).

Usage:
    uv run python app.py

Edit local_config.yaml before running:
    - leader_port: COM port of the leader arm (e.g. COM3)
    - mqtt_broker: LoadBalancer IP from `kubectl get svc publiclistener -n azure-iot-operations`
"""

import json
import sys
import time
from datetime import datetime, timezone
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
        print("  Copy local_config.yaml.example to local_config.yaml and edit it.")
        sys.exit(1)
    with open(config_path) as f:
        return yaml.safe_load(f)

_cfg = load_config()

LEADER_PORT     = _cfg["leader_port"]
LEADER_ID       = _cfg["leader_id"]
CALIBRATION_DIR = _cfg["calibration_dir"]
LOOP_HZ         = float(_cfg["loop_hz"])

MQTT_BROKER     = _cfg["mqtt_broker"]
MQTT_PORT       = int(_cfg["mqtt_port"])
MQTT_TOPIC      = _cfg["mqtt_topic"]
MQTT_CLIENT_ID  = _cfg["mqtt_client_id"]
MQTT_QOS        = int(_cfg["mqtt_qos"])

LOOP_INTERVAL = 1.0 / LOOP_HZ

# ---------------------------------------------------------------------------
# MQTT helpers
# ---------------------------------------------------------------------------

_connected = False


def on_connect(client, userdata, flags, reason_code, properties=None):
    global _connected
    rc = reason_code.value if hasattr(reason_code, "value") else reason_code
    if rc == 0:
        print(f"[OK] Connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
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


def build_mqtt_client() -> mqtt.Client:
    client = mqtt.Client(
        client_id=MQTT_CLIENT_ID,
        protocol=mqtt.MQTTv5,
        transport="tcp",
    )
    client.on_connect    = on_connect
    client.on_disconnect = on_disconnect
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    return client

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("lerobot-leader - SO101 -> AIO MQTT bridge (local Windows)")
    print(f"  Leader port  : {LEADER_PORT}")
    print(f"  Leader ID    : {LEADER_ID}")
    print(f"  Calibration  : {CALIBRATION_DIR}")
    print(f"  Loop rate    : {LOOP_HZ} Hz")
    print(f"  MQTT broker  : {MQTT_BROKER}:{MQTT_PORT}")
    print(f"  Topic        : {MQTT_TOPIC}")
    print(f"  QoS          : {MQTT_QOS}")
    print("=" * 60)

    # --- lerobot_edge imports (deferred so import errors surface clearly) ---
    try:
        from lerobot_edge.teleoperators.so101_leader import SO101Leader, SO101LeaderConfig
    except ImportError as e:
        print(f"[ERROR] Could not import lerobot_edge: {e}")
        print("  Run: uv sync")
        sys.exit(1)

    # Validate calibration file exists before connecting hardware
    calib_path = Path(CALIBRATION_DIR) / f"{LEADER_ID}.json"
    if not calib_path.exists():
        print(f"[ERROR] Calibration file not found: {calib_path}")
        print("  Run: uv run python scripts/03_calibrate_leader.py")
        sys.exit(1)

    # --- Connect leader arm ---
    print(f"\n[...] Connecting to leader arm on {LEADER_PORT} ...")
    leader_config = SO101LeaderConfig(
        port=LEADER_PORT,
        id=LEADER_ID,
        calibration_dir=Path(CALIBRATION_DIR),
    )
    leader = SO101Leader(leader_config)

    try:
        leader.connect(calibrate=False)
        print("[OK] Leader arm connected")
    except Exception as e:
        print(f"[ERROR] Failed to connect to leader arm: {e}")
        print("  Check:")
        print(f"  1. Arm is plugged in and powered on")
        print(f"  2. leader_port={LEADER_PORT} is correct (Device Manager -> Ports)")
        print(f"  3. No other process is using {LEADER_PORT}")
        sys.exit(1)

    # --- Set up MQTT (plain TCP, no TLS, no auth) ---
    print(f"\n[...] Connecting to MQTT broker {MQTT_BROKER}:{MQTT_PORT} ...")
    client = build_mqtt_client()

    try:
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()
    except Exception as e:
        print(f"[ERROR] MQTT connect failed: {e}")
        print("  Check:")
        print(f"  1. mqtt_broker={MQTT_BROKER} is correct")
        print(f"  2. publiclistener is running: kubectl get svc publiclistener -n azure-iot-operations")
        leader.disconnect()
        sys.exit(1)

    # Wait for connection
    for _ in range(10):
        if _connected:
            break
        time.sleep(0.5)
    if not _connected:
        print("[ERROR] Timed out waiting for MQTT connection")
        client.loop_stop()
        leader.disconnect()
        sys.exit(1)

    # --- Publish loop ---
    print(f"\n[OK] Publishing at {LOOP_HZ} Hz. Press Ctrl+C to stop.\n")
    sequence = 0
    stats_interval = 100  # print stats every N messages

    try:
        while True:
            loop_start = time.monotonic()

            try:
                action = leader.get_action()
            except Exception as e:
                print(f"[ERROR] Failed to read leader: {e}")
                time.sleep(1)
                continue

            sequence += 1
            payload = json.dumps({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "leader_id": LEADER_ID,
                "sequence":  sequence,
                "joints":    action,
                "loop_hz":   LOOP_HZ,
            })

            if _connected:
                client.publish(MQTT_TOPIC, payload, qos=MQTT_QOS)
            else:
                print("[WARN] Not connected, skipping publish")

            if sequence % stats_interval == 0:
                print(f"[stats] seq={sequence}  joints={list(action.values())}")

            elapsed = time.monotonic() - loop_start
            sleep_for = LOOP_INTERVAL - elapsed
            if sleep_for > 0:
                time.sleep(sleep_for)

    except KeyboardInterrupt:
        print("\n[...] Shutting down...")
    finally:
        print(f"[stats] Total messages published: {sequence}")
        client.loop_stop()
        client.disconnect()
        leader.disconnect()
        print("[OK] Done")


if __name__ == "__main__":
    main()
