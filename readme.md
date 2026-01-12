# Azure IoT Operations - Learning Repository

This repository provides a complete reference implementation for deploying and managing Azure IoT Operations (AIO) on edge devices, with sample applications demonstrating industrial IoT scenarios.

## What This Repo Is All About

This is a hands-on learning repository for Azure IoT Operations, covering:

- **Edge Infrastructure Setup** - Automated deployment of Azure IoT Operations on Ubuntu/K3s clusters
- **MQTT-Based Asset Management** - Creating and managing industrial assets with MQTT connectivity
- **ARM Template Deployment** - Infrastructure-as-code for deploying assets directly to Azure
- **Sample IoT Applications** - Production-ready edge applications including simulators and data processors
- **Troubleshooting & Diagnostics** - Scripts and guides for debugging common AIO issues
- **Cloud Integration** - Connecting edge devices to Azure Fabric, Real-Time Intelligence, and other services

The repository demonstrates real-world patterns for industrial IoT deployments, from initial cluster setup through application deployment and cloud integration.

## Repository Structure

| Folder | Purpose | Key Contents |
|--------|---------|--------------|
| **`linux_build/`** | AIO infrastructure deployment on Ubuntu/K3s | `linux_installer.sh` (edge setup), `External-Configurator.ps1` (Azure config), diagnostic scripts, ARM templates, configuration templates |
| **`linux_build/arm_templates/`** | ARM templates for Azure resources | MQTT asset definitions, endpoint profiles for deploying assets to Azure Resource Manager |
| **`linux_build/assets/`** | Kubernetes asset manifests | YAML definitions for MQTT assets to deploy on the edge cluster |
| **`iotopps/`** | Edge applications and workloads | Production IoT applications that run on the AIO cluster |
| **`iotopps/edgemqttsim/`** | MQTT telemetry simulator | Factory equipment simulator publishing realistic telemetry to MQTT broker |
| **`iotopps/hello-flask/`** | Sample Flask web application | Basic containerized web app for testing deployments |
| **`iotopps/sputnik/`** | MQTT test publisher | Simple MQTT client sending periodic "beep" messages for testing |
| **`iotopps/demohistorian/`** | SQL-based MQTT historian | Subscribes to all topics, stores in PostgreSQL, provides HTTP API for queries |
| **`iotopps/wasm-quality-filter-python/`** | WebAssembly data filter | WASM-based telemetry filtering for edge processing |
| **`Fabric_setup/`** | Azure Fabric integration | Documentation and queries for connecting AIO to Microsoft Fabric Real-Time Intelligence |
| **`operations/`** | Operational configurations | Azure resource definitions for data pipelines and endpoints |
| **`certs/`** | SSL/TLS certificates | Base64-encoded certificates for secure MQTT connections |

## Quick Start

The deployment process is split into two distinct phases for better security and flexibility.

### Phase 1: Edge Device Setup (`linux_installer.sh`)
Run on the edge device to prepare local infrastructure:
```bash
# On Ubuntu edge device (24.04+, 16GB RAM, 4 CPU cores minimum)
cd linux_build
bash linux_installer.sh
```

**Installs**: K3s cluster, kubectl, Helm, optional tools (k9s, mqtt-viewer, mqttui), edge modules  
**Output**: `edge_configs/cluster_info.json` for remote configuration  
**Configuration**: Uses `linux_aio_config.json` for optional_tools and modules settings

### Phase 2: Azure Configuration (`External-Configurator.ps1`)
Run from any Windows machine with Azure CLI to connect and deploy AIO:
```powershell
# On DevOps machine, developer workstation, or CI/CD pipeline
cd linux_build
.\External-Configurator.ps1 -ConfigFile ".\edge_configs\cluster_info.json"
```

**Configures**: Azure Arc, resource groups, AIO deployment, asset sync  
**Benefits**: No Azure credentials needed on edge device, supports multi-cluster management

### Verify Deployment

```bash
# Check AIO pods are running
kubectl get pods -n azure-iot-operations

# Verify assets in Azure
az resource list --resource-group <YOUR_RG> --resource-type Microsoft.DeviceRegistry/assets -o table

# Monitor MQTT messages
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t 'factory/#' -v
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

## Architecture

This repository demonstrates a modern edge-to-cloud architecture with separated edge infrastructure and cloud orchestration.

### Separated Architecture

The deployment architecture divides the process into two distinct phases for better security and maintainability:

```
┌────────────────────────────────────────────────────────────────┐
│  Phase 1: Edge Device Setup (linux_installer.sh)              │
│  Runs ON the edge device                                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  Edge Device (Ubuntu + K3s)                              │ │
│  │  • System preparation & validation                       │ │
│  │  • K3s cluster installation                              │ │
│  │  • kubectl & Helm installation                           │ │
│  │  • Local system configuration                            │ │
│  │  Output: cluster_info.json                               │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ Transfer cluster_info.json
                              │ (Secure copy to management machine)
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Phase 2: Azure Configuration (External-Configurator.ps1)     │
│  Runs FROM any Windows machine with Azure CLI                 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  Remote Configuration Machine                            │ │
│  │  • Azure Arc enablement                                  │ │
│  │  • Resource group & namespace creation                   │ │
│  │  • AIO instance deployment                               │ │
│  │  • Asset synchronization                                 │ │
│  │  • Multi-cluster management                              │ │
│  │  Output: deployment_summary.json                         │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ Azure Arc Connection
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Azure Cloud Resources                                         │
│  • Arc-enabled Kubernetes (connected edge cluster)            │
│  • Azure IoT Operations instance                              │
│  • Device Registry (Assets)                                   │
│  • Schema Registry & Storage                                  │
│  • Microsoft Fabric integration                               │
└────────────────────────────────────────────────────────────────┘
```

**Benefits of Separated Architecture**:
- 🔒 **Security**: No Azure credentials needed on edge devices
- 📡 **Remote Management**: Configure multiple edge devices from central location
- 🔄 **CI/CD Friendly**: Easy pipeline integration for GitOps workflows
- 🐛 **Easier Debugging**: Clear separation of local vs. cloud issues
- 🏢 **Production Ready**: Follows best practices for enterprise deployments
- 🎯 **Modular Deployment**: Configure edge modules (edgemqttsim, demohistorian, etc.) via config file

## Prerequisites

- **Hardware**: 16GB RAM minimum, 4 CPU cores, 50GB disk space
- **OS**: Ubuntu 24.04 LTS (or compatible Linux distribution)
- **Azure**: Active Azure subscription with appropriate permissions
- **Tools**: Azure CLI, kubectl, docker/containerd

## Contributing

This is a learning repository. Feel free to:
- Add new sample applications to `iotopps/`
- Improve diagnostic scripts in `linux_build/`
- Contribute troubleshooting tips and solutions
- Share integration examples with other Azure services

## Related Resources

- [Azure IoT Operations Documentation](https://learn.microsoft.com/azure/iot-operations/)
- [K3s Documentation](https://docs.k3s.io/)
- [MQTT Protocol Specification](https://mqtt.org/)
- [Azure Arc Documentation](https://learn.microsoft.com/azure/azure-arc/)

This setup enables edge computing capabilities with local MQTT brokers, data processing pipelines, and integration with Azure cloud services.

