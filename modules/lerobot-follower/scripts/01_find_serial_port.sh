#!/usr/bin/env bash
# 01_find_serial_port.sh
# Finds the serial port for the SO101 follower arm on Linux.

set -euo pipefail

echo "=== SO101 Follower Arm - Serial Port Finder ==="
echo ""

# Show all likely serial devices
echo "Current serial devices:"
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  (none found)"
echo ""

# Try to match by USB vendor/product via udevadm
echo "USB serial devices with details:"
found=0
for dev in /dev/ttyUSB* /dev/ttyACM* 2>/dev/null; do
    [ -e "$dev" ] || continue
    found=1
    info=$(udevadm info --query=property --name="$dev" 2>/dev/null)
    vendor=$(echo "$info" | grep -E "^ID_VENDOR=" | cut -d= -f2)
    model=$(echo "$info" | grep -E "^ID_MODEL=" | cut -d= -f2)
    serial=$(echo "$info" | grep -E "^ID_SERIAL_SHORT=" | cut -d= -f2)
    echo "  $dev  vendor=${vendor:-unknown}  model=${model:-unknown}  serial=${serial:-unknown}"
done

if [ "$found" -eq 0 ]; then
    echo "  No USB serial devices found."
    echo ""
    echo "Troubleshooting:"
    echo "  - Make sure the arm is powered on and the USB cable is connected."
    echo "  - Run: lsusb   to see if the USB device is detected at all."
    echo "  - Run: dmesg | tail -20   right after plugging in for kernel messages."
    exit 1
fi

echo ""
echo "Watch for new device when you plug in / unplug the arm:"
echo "  dmesg | tail -20"
echo ""

# Suggest config update
echo "Once you know the port (e.g. /dev/ttyUSB0), update local_config.yaml:"
echo "  follower_port: \"/dev/ttyUSB0\""
echo ""

# Check group membership for serial port access
if ! groups | grep -qE "dialout|tty"; then
    echo "WARNING: Your user is not in the 'dialout' or 'tty' group."
    echo "You may get a 'Permission denied' error when opening the port."
    echo "Fix with:  sudo usermod -aG dialout \$USER"
    echo "Then log out and back in (or run: newgrp dialout)"
fi
