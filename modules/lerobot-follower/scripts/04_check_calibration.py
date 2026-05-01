"""
04_check_calibration.py - Verify follower arm calibration

Loads the calibration file, connects to the arm, and prints the stored
calibration data so you can confirm it looks reasonable.

Usage:
    uv run python scripts/04_check_calibration.py
"""

import json
import sys
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

FOLLOWER_PORT     = cfg["follower_port"]
FOLLOWER_ID       = cfg["follower_id"]
CALIBRATION_DIR   = Path(cfg["calibration_dir"]).resolve()

# ---------------------------------------------------------------------------
# Check calibration file
# ---------------------------------------------------------------------------

calib_file = CALIBRATION_DIR / f"{FOLLOWER_ID}.json"

print("=" * 60)
print("SO101 Follower Arm - Calibration Check")
print(f"  Port          : {FOLLOWER_PORT}")
print(f"  Follower ID   : {FOLLOWER_ID}")
print(f"  Calibration   : {calib_file}")
print("=" * 60)
print()

if not calib_file.exists():
    print(f"[ERROR] Calibration file not found: {calib_file}")
    print("  Run calibration first:")
    print("    uv run python scripts/03_calibrate_follower.py")
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
    from lerobot_edge.robots.so101_follower import SO101Follower, SO101FollowerConfig
except ImportError as e:
    print(f"[ERROR] Could not import lerobot_edge: {e}")
    print("  Run: uv sync")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Connect and read present position
# ---------------------------------------------------------------------------

print("[...] Connecting to arm...")
follower_config = SO101FollowerConfig(
    port=FOLLOWER_PORT,
    id=FOLLOWER_ID,
    calibration_dir=CALIBRATION_DIR,
)
follower = SO101Follower(follower_config)

try:
    follower.connect(calibrate=False)
    print("[OK] Connected. Reading present joint positions...\n")
    obs = follower.get_observation()
    joints = {k: v for k, v in obs.items() if k.endswith(".pos")}
    print("Current joint positions:")
    for name, val in joints.items():
        print(f"  {name:20s}: {val:.2f}")
    print()
    print("[OK] If these values look reasonable, calibration is good.")
    print("     Move the arm manually and re-run to verify positions change.")
except Exception as e:
    print(f"[ERROR] {e}")
finally:
    follower.disconnect()
