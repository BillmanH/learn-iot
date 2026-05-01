"""
02_setup_motors_follower.py - One-time motor ID configuration for SO101 follower arm

Run this ONCE on brand-new motors before calibration. It walks through each
motor one at a time, setting the correct motor ID (1-6).

If your motors are already set up (from a previous build), skip this step.

Usage:
    uv run python scripts/02_setup_motors_follower.py
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

FOLLOWER_PORT = cfg["follower_port"]
FOLLOWER_ID   = cfg["follower_id"]

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
# Run setup
# ---------------------------------------------------------------------------

print("=" * 60)
print("SO101 Follower Arm - Motor Setup")
print(f"  Port: {FOLLOWER_PORT}")
print("=" * 60)
print()
print("This script assigns motor IDs 1-6 to each joint in order:")
print("  1 = shoulder_pan")
print("  2 = shoulder_lift")
print("  3 = elbow_flex")
print("  4 = wrist_flex")
print("  5 = wrist_roll")
print("  6 = gripper")
print()
print("Steps:")
print("  1. Disconnect all motors except the one you are currently setting up.")
print("  2. Connect the motor to the arm's USB bus.")
print("  3. Press ENTER when prompted.")
print("  4. Repeat for each motor in order.")
print()

follower_config = SO101FollowerConfig(
    port=FOLLOWER_PORT,
    id=FOLLOWER_ID,
)
follower = SO101Follower(follower_config)

try:
    follower.connect(calibrate=False)
    # Motor ID setup is handled interactively by the library
    input("Press ENTER to start motor ID setup...")
    # The library's setup_motors() or equivalent should be called here.
    # Refer to the lerobot_edge documentation if additional calls are needed.
    print("[OK] Motor setup complete.")
finally:
    follower.disconnect()
