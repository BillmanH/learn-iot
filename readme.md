# Azure IoT Operations - Quick Start

Automated deployment of Azure IoT Operations (AIO) on edge devices with industrial IoT applications.

## What You Get

- ⚡ **One-command edge setup** - Automated K3s cluster with Azure IoT Operations
- 🏭 **Industrial IoT apps** - Factory simulator, MQTT historian, data processors
- ☁️ **Cloud integration** - Microsoft Fabric Real-Time Intelligence connectivity
- 🔧 **Production-ready** - Separation of edge and cloud configuration for security

> **For detailed technical information, see [README_ADVANCED.md](README_ADVANCED.md)**

# Quick Start

![Process Overview](./img/process_1.png)

## Prerequisites

- **Hardware**: Ubuntu machine with 16GB RAM, 4 CPU cores, 50GB disk
- **Azure**: Active subscription with admin access
- **Network**: Internet connectivity (edge device and management machine)

## Installation

### 1. Clone Repository

```bash
git clone https://github.com/yourusername/learn-iothub.git
cd learn-iothub
```

### 2. Create and Complete Config File ⚠️ **DO THIS FIRST**

**Before running any installation scripts**, create and configure `linux_aio_config.json`:

```bash
cd linux_build
cp linux_aio_config.template.json linux_aio_config.json
```

Edit `linux_aio_config.json` with your settings:
- Azure subscription ID
- Resource group name
- Location (e.g., "eastus")
- Cluster name
- Optional tools to install (k9s, mqtt-viewer, mqttui)
- Edge modules to deploy (edgemqttsim, demohistorian, etc.)

**This config file controls the entire deployment.** Review it carefully before proceeding.

### 3. Edge Setup (On Ubuntu Device)

```bash
cd linux_build
bash linux_installer.sh
```

**What it does**: Installs K3s, kubectl, Helm, and prepares cluster for Azure IoT Operations  
**Time**: ~10-15 minutes  
**Output**: `edge_configs/cluster_info.json` (needed for next step)

> **Note**: System may restart during installation. This is normal. Rerun the script after restart to continue.
![k9s pre iot](./img/k9s-pre-iot.jpg)
After this you should see the core arc-kubernetes components on your nuc device. 
You can also use the proxy service at:
```
az connectedk8s proxy --name <your-cluster> --resource-group <your resource group>
```
You'll need this when you get to troubleshooting later. 

![reosources pre iot](./img/azure-resources-pre-iot.png)

### 4. Azure Configuration (From Windows Machine)

```powershell
# Prerequisites: Install Azure CLI and login
az login

# Configure Azure resources and connect edge cluster
cd linux_build
.\External-Configurator.ps1 -ConfigFile ".\edge_configs\cluster_info.json"
```

**What it does**: Azure Arc enablement, AIO deployment, asset synchronization  
**Time**: ~15-20 minutes  
**Benefit**: No Azure credentials needed on edge device

![k9s post iot](./img/k9s-post-iot.jpg)
![reosources post iot](./img/azure-resources-post-iot.png)

### 5. Verify Installation

```bash
# Check pods are running
kubectl get pods -n azure-iot-operations

# View MQTT messages
kubectl logs -n azure-iot-operations -l app=aio-broker-frontend --tail=20
```

## Key Documentation

### Infrastructure & Setup

- **[Linux Build Steps](./linux_build/linux_build_steps.md)** - Complete step-by-step guide for installing AIO on a fresh Linux system
- **[K3s Troubleshooting Guide](./linux_build/K3S_TROUBLESHOOTING_GUIDE.md)** - Comprehensive troubleshooting reference for K3s cluster issues
- **[Azure Portal Setup](./aio_portal_setup.md)** - Guide for discovering and managing devices in Azure Portal
- **`linux_installer.sh`** - Edge device installer (local infrastructure only)
- **`External-Configurator.ps1`** - Remote Azure configurator (cloud resources only)
- **`Deploy-EdgeModules.ps1`** - Automated deployment script for edge applications
- **`Deploy-Assets.ps1`** - ARM template deployment script for Azure assets

### Applications & Samples

- **[Edge MQTT Simulator](./iotopps/edgemqttsim/README.md)** - Comprehensive factory telemetry simulator
- **[Edge Historian](./iotopps/demohistorian/README.md)** - SQL-based historian with HTTP API for querying historical MQTT data
- **[Fabric Integration](./Fabric_setup/fabric-realtime-intelligence-setup.md)** - Connecting AIO to Microsoft Fabric

### Development Environment

Create the Python environment using uv:
```bash
uv sync
```

## What's Included

### Edge Applications (`iotopps/`)
- **edgemqttsim** - Factory equipment simulator (CNC, 3D printer, welding, etc.)
- **demohistorian** - SQL-based MQTT historian with HTTP API
- **sputnik** - Simple MQTT test publisher
- **hello-flask** - Basic web app for testing

### Key Directories
- **`linux_build/`** - Installation scripts and ARM templates
- **`Fabric_setup/`** - Microsoft Fabric Real-Time Intelligence integration
- **`operations/`** - Dataflow configurations for cloud connectivity

## Configuration

Customize deployment via `linux_build/linux_aio_config.json`:
- Azure subscription and resource group settings
- Optional tools (k9s, MQTT viewers)
- Edge modules to deploy
- Fabric Event Stream integration

## Next Steps

After installation:

1. **View MQTT messages**: See [README_ADVANCED.md](README_ADVANCED.md#monitoring-mqtt-traffic)
2. **Deploy applications**: See [README_ADVANCED.md](README_ADVANCED.md#deploying-edge-applications)
3. **Connect to Fabric**: See [README_ADVANCED.md](README_ADVANCED.md#fabric-integration)
4. **Troubleshooting**: See [README_ADVANCED.md](README_ADVANCED.md#troubleshooting)

## Documentation

- **[README_ADVANCED.md](README_ADVANCED.md)** - Detailed technical guide
- **[Bug Reports](operations/)** - Known issues and workarounds
- **[Application READMEs](iotopps/)** - Individual app documentation

## Support

- [Azure IoT Operations Docs](https://learn.microsoft.com/azure/iot-operations/)
- [K3s Documentation](https://docs.k3s.io/)
- [Issue Tracker](https://github.com/yourusername/learn-iothub/issues)