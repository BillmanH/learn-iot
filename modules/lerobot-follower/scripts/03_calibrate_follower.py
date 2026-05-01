"""
03_calibrate_follower.py - Calibrate the SO101 follower arm

Runs the interactive calibration procedure and saves the result to:
    ./calibration/<follower_id>.json

This file is loaded by app.py on every run. Repeat calibration any time
the arm's zero position drifts or after reassembly.

Usage:
    uv run python scripts/03_calibrate_follower.py
"""

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
# Import lerobot_edge
# ---------------------------------------------------------------------------

try:
    from lerobot_edge.robots.so101_follower import SO101Follower, SO101FollowerConfig
except ImportError as e:
    print(f"[ERROR] Could not import lerobot_edge: {e}")
    print("  Run: uv sync")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Run calibration
# ---------------------------------------------------------------------------

print("=" * 60)
print("SO101 Follower Arm - Calibration")
print(f"  Port          : {FOLLOWER_PORT}")
print(f"  Follower ID   : {FOLLOWER_ID}")
print(f"  Calibration   : {CALIBRATION_DIR / (FOLLOWER_ID + '.json')}")
print("=" * 60)
print()
print("The calibration procedure will:")
print("  1. Ask you to move the arm to the middle of its range and press ENTER")
print("  2. Ask you to move all joints through their full range, then press ENTER")
print()

follower_config = SO101FollowerConfig(
    port=FOLLOWER_PORT,
    id=FOLLOWER_ID,
    calibration_dir=CALIBRATION_DIR,
)
follower = SO101Follower(follower_config)

try:
    # connect(calibrate=True) runs the interactive calibration and saves the file
    follower.connect(calibrate=True)
    calib_file = CALIBRATION_DIR / f"{FOLLOWER_ID}.json"
    if calib_file.exists():
        print()
        print(f"[OK] Calibration saved to: {calib_file}")
        print()
        print("Next step - verify the calibration:")
        print("  uv run python scripts/04_check_calibration.py")
    else:
        print()
        print(f"[WARN] Calibration file not found at expected path: {calib_file}")
        print("  The library may have saved it elsewhere. Check the output above.")
except KeyboardInterrupt:
    print("\n[...] Calibration interrupted.")
finally:
    follower.disconnect()
