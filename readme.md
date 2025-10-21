# Azure IOT-HUB

Create the enviornment using uv:
```bash
uv sync
```

## Linux Build - Azure IoT Operations Setup

The `linux_build/` directory contains scripts and documentation for setting up Azure IoT Operations (AIO) on Ubuntu Linux with K3s Kubernetes cluster.

### Key Resources:
- **[Linux Build Steps](./linux_build/linux_build_steps.md)** - Complete step-by-step guide for installing AIO on a fresh Linux system
- **[K3s Troubleshooting Guide](./linux_build/K3S_TROUBLESHOOTING_GUIDE.md)** - Comprehensive troubleshooting reference for K3s cluster issues
- **`linuxAIO.sh`** - Automated installation script for Azure IoT Operations
- **Configuration files** - JSON templates and configuration examples

### Quick Start:
1. Ensure you have Ubuntu 24.04+ with minimum 16GB RAM and 4 CPU cores
2. Run the automated installation script: `./linuxAIO.sh`
3. If you encounter issues, refer to the troubleshooting guide

This setup enables edge computing capabilities with local MQTT brokers, data processing pipelines, and integration with Azure cloud services.

