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
| **`linux_build/`** | AIO infrastructure deployment on Ubuntu/K3s | `linuxAIO.sh` (automated installer), diagnostic scripts, ARM templates for asset deployment, configuration templates |
| **`linux_build/arm_templates/`** | ARM templates for Azure resources | MQTT asset definitions, endpoint profiles for deploying assets to Azure Resource Manager |
| **`linux_build/assets/`** | Kubernetes asset manifests | YAML definitions for MQTT assets to deploy on the edge cluster |
| **`iotopps/`** | Edge applications and workloads | Production IoT applications that run on the AIO cluster |
| **`iotopps/edgemqttsim/`** | MQTT telemetry simulator | Factory equipment simulator publishing realistic telemetry to MQTT broker |
| **`iotopps/hello-flask/`** | Sample Flask web application | Basic containerized web app for testing deployments |
| **`iotopps/sputnik/`** | Custom IoT application | Specialized edge processing application |
| **`iotopps/wasm-quality-filter-python/`** | WebAssembly data filter | WASM-based telemetry filtering for edge processing |
| **`Fabric_setup/`** | Azure Fabric integration | Documentation and queries for connecting AIO to Microsoft Fabric Real-Time Intelligence |
| **`operations/`** | Operational configurations | Azure resource definitions for data pipelines and endpoints |
| **`certs/`** | SSL/TLS certificates | Base64-encoded certificates for secure MQTT connections |

## Quick Start

### 1. Deploy Azure IoT Operations Infrastructure

```bash
# On your Ubuntu edge device (24.04+, 16GB RAM, 4 CPU cores minimum)
cd linux_build
bash linuxAIO.sh
```

This script will:
- Install K3s Kubernetes cluster
- Deploy Azure IoT Operations v1.2+
- Configure MQTT broker and authentication
- Set up Arc-enabled Kubernetes connection to Azure

### 2. Deploy Assets to Azure

After infrastructure is ready, deploy MQTT assets to Azure Resource Manager:

```bash
cd linux_build
bash deploy-assets.sh
```

This creates:
- MQTT Asset Endpoint Profile (connection to edge broker)
- Factory MQTT Asset (telemetry definitions)

### 3. Deploy Sample Applications

```bash
cd iotopps/edgemqttsim
# Update <YOUR_REGISTRY> in deployment.yaml
kubectl apply -f deployment.yaml
```

### 4. Verify Deployment

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
- **`linuxAIO.sh`** - Automated installation script for Azure IoT Operations
- **`deploy-assets.sh`** - ARM template deployment script for Azure assets

### Applications & Samples

- **[Edge MQTT Simulator](./iotopps/edgemqttsim/README.md)** - Comprehensive factory telemetry simulator
- **[Fabric Integration](./Fabric_setup/fabric-realtime-intelligence-setup.md)** - Connecting AIO to Microsoft Fabric

### Development Environment

Create the Python environment using uv:
```bash
uv sync
```

## Architecture

This repository demonstrates a modern edge-to-cloud architecture:

```
┌─────────────────────────────────────────────┐
│   Edge Device (Ubuntu + K3s)                │
│   ┌─────────────────────────────────────┐   │
│   │  Azure IoT Operations               │   │
│   │  - MQTT Broker (aio-broker)         │   │
│   │  - Asset Management                 │   │
│   │  - Authentication (K8S-SAT)         │   │
│   └─────────────────────────────────────┘   │
│   ┌─────────────────────────────────────┐   │
│   │  IoT Applications                   │   │
│   │  - edgemqttsim (telemetry)          │   │
│   │  - wasm filters (processing)        │   │
│   └─────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
                    │
                    │ Arc-enabled K8s
                    ▼
┌─────────────────────────────────────────────┐
│   Azure Cloud                               │
│   - Device Registry (Assets)                │
│   - Microsoft Fabric (Data Analytics)       │
│   - Real-Time Intelligence                  │
└─────────────────────────────────────────────┘
```

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

