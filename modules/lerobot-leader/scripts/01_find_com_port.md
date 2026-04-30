# How to Find the Leader Arm COM Port on Windows

The SO101 leader arm shows up as a USB Serial (CDC) device on Windows.
You need to know its COM port number before editing `local_config.yaml`.

## Steps

1. Plug in the leader arm USB cable. Make sure the arm is powered on.

2. Open **Device Manager**:
   - Press `Win + X` → Device Manager
   - Or: Run → `devmgmt.msc`

3. Expand **Ports (COM & LPT)**.

4. Look for a new entry such as:
   - `USB Serial Device (COM3)`
   - `USB-SERIAL CH340 (COM4)`
   - `STMicroelectronics Virtual COM Port (COM5)`

   The exact name depends on the arm's USB chip. If you're not sure which one,
   unplug the arm, note what ports are listed, then plug it back in and see
   what appears.

5. Note the COM number (e.g., `COM3`).

6. Edit `local_config.yaml` in the `lerobot-leader` folder:
   ```yaml
   leader_port: "COM3"   # <-- set this to your COM number
   ```

## Tips

- If the port doesn't appear, try a different USB cable or port.
- If Device Manager shows a yellow warning icon, install the driver:
  - CH340/CH341 chip: https://www.wch-ic.com/downloads/CH341SER_EXE.html
  - CP2102 chip: install via "Silicon Labs CP210x" driver from Silicon Labs
- Only one process can open a COM port at a time. Close any other serial
  monitor (PuTTY, Tera Term, Arduino IDE) before running the scripts.
