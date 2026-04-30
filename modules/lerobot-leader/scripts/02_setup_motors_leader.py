"""
02_setup_motors_leader.py - One-time motor ID configuration for SO101 leader arm

Run this ONCE on brand-new motors before calibration. It walks through each
motor one at a time, setting the correct motor ID (1-6).

If your motors are already set up (from a previous build), skip this step.

Usage:
    uv run python scripts/02_setup_motors_leader.py
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

LEADER_PORT = cfg["leader_port"]
LEADER_ID   = cfg["leader_id"]

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
# Run setup
# ---------------------------------------------------------------------------

print("=" * 60)
print("SO101 Leader Arm - Motor Setup")
print(f"  Port: {LEADER_PORT}")
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
print("You will be prompted to connect ONE motor at a time to the controller board.")
print("Follow the prompts carefully.")
print()
input("Press ENTER to begin...")

leader_config = SO101LeaderConfig(
    port=LEADER_PORT,
    id=LEADER_ID,
    calibration_dir=None,   # not needed for motor setup
)
leader = SO101Leader(leader_config)
leader.bus.connect()

try:
    leader.setup_motors()
    print()
    print("[OK] Motor setup complete.")
    print("  Reconnect all motors to the daisy chain and proceed to calibration:")
    print("  uv run python scripts/03_calibrate_leader.py")
finally:
    leader.bus.disconnect()
