"""
04_check_calibration.py - Verify leader arm calibration and read live joint positions

Loads the calibration file, connects to the arm, and prints live joint positions
for 5 seconds so you can verify the arm is working correctly.

Usage:
    uv run python scripts/04_check_calibration.py
"""

import json
import sys
import time
from pathlib import Path

import yaml

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

CONFIG_PATH = Path(__file__).parent.parent / "local_config.yaml"

if not CONFIG_PATH.exists():
    print(f"[ERROR] Config not found: {CONFIG_PATH}")
    sys.exit(1)

with open(CONFIG_PATH) as f:
    cfg = yaml.safe_load(f)

LEADER_PORT     = cfg["leader_port"]
LEADER_ID       = cfg["leader_id"]
CALIBRATION_DIR = Path(cfg["calibration_dir"]).resolve()

# ---------------------------------------------------------------------------
# Check calibration file
# ---------------------------------------------------------------------------

calib_file = CALIBRATION_DIR / f"{LEADER_ID}.json"

print("=" * 60)
print("SO101 Leader Arm - Calibration Check")
print(f"  Port          : {LEADER_PORT}")
print(f"  Leader ID     : {LEADER_ID}")
print(f"  Calibration   : {calib_file}")
print("=" * 60)
print()

if not calib_file.exists():
    print(f"[ERROR] Calibration file not found: {calib_file}")
    print("  Run calibration first:")
    print("    uv run python scripts/03_calibrate_leader.py")
    sys.exit(1)

with open(calib_file) as f:
    calib_data = json.load(f)

print("[OK] Calibration file found. Contents:")
for motor, values in calib_data.items():
    print(f"  {motor:15s}: {values}")
print()

# ---------------------------------------------------------------------------
# Import lerobot_edge
# ---------------------------------------------------------------------------

try:
    from lerobot_edge.teleoperators.so101_leader import SO101Leader, SO101LeaderConfig
except ImportError as e:
    print(f"[ERROR] Could not import lerobot_edge: {e}")
    print("  Run: uv sync")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Connect and read live positions
# ---------------------------------------------------------------------------

print("[...] Connecting to arm...")
leader_config = SO101LeaderConfig(
    port=LEADER_PORT,
    id=LEADER_ID,
    calibration_dir=CALIBRATION_DIR,
)
leader = SO101Leader(leader_config)

try:
    leader.connect(calibrate=False)
    print("[OK] Connected. Reading joint positions for 5 seconds (move the arm!)...\n")

    start = time.monotonic()
    while time.monotonic() - start < 5.0:
        action = leader.get_action()
        vals = "  ".join(f"{k}={v:+.1f}" for k, v in action.items())
        print(f"\r  {vals}", end="", flush=True)
        time.sleep(0.1)

    print()
    print()
    print("[OK] Check complete. If joints moved when you moved the arm, calibration is good.")
    print("  Run the application:")
    print("    uv run python app.py")

except Exception as e:
    print(f"\n[ERROR] Failed to connect: {e}")
    print("  Check that the arm is plugged in and LEADER_PORT is correct.")
    sys.exit(1)
finally:
    leader.disconnect()
