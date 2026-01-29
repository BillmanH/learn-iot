# Azure IoT Operations - Windows Edge Device Installer

Automated deployment of Azure IoT Operations development environment on Windows machines.

## Overview

This installer prepares a Windows machine for Azure IoT Operations development by setting up a local Kubernetes cluster using either:
- **WSL2 + K3s** (recommended) - K3s runs inside Ubuntu WSL2
- **K3d** (alternative) - K3s runs in Docker containers

## Prerequisites

- **Windows 10** (Build 19041+) or **Windows 11**
- **Administrator privileges**
- **16GB+ RAM** (32GB recommended)
- **50GB+ free disk space**
- **Internet connectivity**

### For K3d Option (alternative)
- Docker Desktop installed and running

## Quick Start

### 1. Open PowerShell as Administrator

```powershell
# Right-click PowerShell → Run as Administrator
```

### 2. Navigate to windows_build folder

```powershell
cd C:\path\to\learn-iot\windows_build
```

### 3. (Optional) Create Configuration File

```powershell
Copy-Item windows_aio_config.template.json windows_aio_config.json
# Edit windows_aio_config.json with your settings
```

### 4. Run the Installer

```powershell
# Standard installation (WSL2 + K3s)
.\windows_install.ps1

# Or with K3d (requires Docker Desktop)
.\windows_install.ps1 -UseK3d
```

### 5. Reboot if Required

The script will prompt you to reboot if Windows features were enabled. After rebooting, run the script again.

### 6. Configure Azure Resources

After installation completes, use External-Configurator.ps1:

```powershell
cd ..\linux_build
.\External-Configurator.ps1
```

## Installation Options

| Parameter | Description |
|-----------|-------------|
| `-DryRun` | Validate configuration without making changes |
| `-UseK3d` | Use K3d (Docker) instead of WSL2 K3s |
| `-ForceReinstall` | Force reinstall of all components |
| `-SkipVerification` | Skip post-installation verification |
| `-ConfigFile <path>` | Use specific configuration file |

## What Gets Installed

### Windows Features
- Windows Subsystem for Linux (WSL2)
- Virtual Machine Platform
- Containers (if using K3d)

### Tools (via Chocolatey)
- **kubectl** - Kubernetes CLI
- **helm** - Kubernetes package manager
- **Azure CLI** - Azure command-line tools
- **k9s** (optional) - Terminal UI for Kubernetes
- **mosquitto** (optional) - MQTT CLI tools

### Kubernetes
- **K3s** (via WSL2) or **K3d** (via Docker)
- **CSI Secret Store Driver** - Azure Key Vault integration
- **Azure Key Vault Provider** - Secret synchronization

## Output Files

After successful installation:

```
windows_build/
├── edge_configs/
│   └── cluster_info.json    # Cluster details for External-Configurator.ps1
└── windows_installer_*.log  # Installation log
```

## WSL2 vs K3d

| Feature | WSL2 + K3s | K3d |
|---------|------------|-----|
| Performance | Better | Good |
| Resources | Lower | Higher (Docker overhead) |
| Persistence | Survives reboots | Containers may need restart |
| Setup | Auto-configured | Requires Docker Desktop |
| Linux Tools | Full Ubuntu access | Limited |

**Recommendation**: Use WSL2 + K3s unless you already have Docker Desktop installed.

## Troubleshooting

### WSL2 Issues

```powershell
# Check WSL status
wsl --status

# Update WSL
wsl --update

# List installed distributions
wsl --list --verbose

# Restart WSL
wsl --shutdown
```

### Cluster Connectivity Issues

```powershell
# Check if K3s is running (WSL)
wsl -d Ubuntu-24.04 -- sudo systemctl status k3s

# Restart K3s (WSL)
wsl -d Ubuntu-24.04 -- sudo systemctl restart k3s

# For K3d - restart cluster
k3d cluster stop <cluster-name>
k3d cluster start <cluster-name>
```

### kubectl Connection Issues

```powershell
# Verify kubeconfig
kubectl config view

# Test cluster connection
kubectl cluster-info

# For WSL - get fresh kubeconfig
wsl -d Ubuntu-24.04 -- cat ~/.kube/config > $env:USERPROFILE\.kube\config
```

### Docker Desktop Issues (K3d only)

1. Ensure Docker Desktop is running
2. Check Docker is using WSL2 backend (Settings → General → Use WSL 2)
3. Restart Docker Desktop

## Next Steps

After installation:

1. **Verify cluster is running**
   ```powershell
   kubectl get nodes
   kubectl get pods -A
   ```

2. **Run External-Configurator.ps1** to:
   - Arc-enable the cluster
   - Deploy Azure IoT Operations
   - Configure Key Vault integration

3. **Deploy edge modules** using Deploy-EdgeModules.ps1

## Comparison with Linux Installer

| Feature | Linux (linux_installer.sh) | Windows (windows_install.ps1) |
|---------|---------------------------|-------------------------------|
| Kubernetes | Native K3s | K3s in WSL2 or K3d |
| Package Manager | apt | Chocolatey |
| Shell | Bash | PowerShell |
| Production Use | ✓ Recommended | Development only |

**Note**: Windows installations are primarily for development and testing. For production edge deployments, use Linux.

## Related Documentation

- [Linux Build Steps](../linux_build/linux_build_steps.md)
- [External Configurator](../linux_build/External-Configurator.ps1)
- [Main README](../readme.md)
