# Azure IoT Operations - Quick Start

Two-step installation: (1) Edge setup (2) Azure deployment

## Prerequisites
- Ubuntu 24.04+, 16GB RAM, 4+ cores
- Active Azure subscription
- Git repository cloned

## Step 1: Edge Device Setup

**On Linux edge device:**
```bash
cd ~/learn-iothub/linux_build

# Edit config (set resource_group, location, cluster_name)
nano linux_aio_config.json

# Run installer
chmod +x linux_installer.sh
./linux_installer.sh

# For clean reinstall:
./linux_installer.sh --force-reinstall

# To completely remove everything:
./linux_aio_cleanup.sh
```

This installs:
- K3s Kubernetes cluster
- kubectl, Helm, Azure CLI
- Azure Arc agents
- CSI Secret Store (for Key Vault integration)

**Time:** 15-25 minutes

## Step 2: Azure IoT Operations Deployment

**On Windows management machine:**

```powershell
cd C:\path\to\learn-iothub\linux_build

# Deploy Azure IoT Operations
.\External-Configurator.ps1 -UseArcProxy

# Or specify files explicitly:
.\External-Configurator.ps1 `
  -ClusterInfo ".\edge_configs\cluster_info.json" `
  -ConfigFile ".\linux_aio_config.json" `
  -UseArcProxy
```

This deploys:
- Azure IoT Operations (via Arc)
- MQTT broker and dataflow pipelines
- Device Registry and assets (optional)

**Time:** 10-15 minutes

## Configuration File

Edit `linux_aio_config.json`:
```json
{
  "azure": {
    "subscription_id": "",
    "resource_group": "IoT-Operations",
    "location": "westus2",
    "cluster_name": "iot-ops-cluster",
    "namespace_name": "iot-operations-ns"
  },
  "deployment": {
    "deployment_mode": "test"
  }
}
```

## Common Commands

```bash
# Check cluster health
kubectl get pods --all-namespaces

# View Arc status
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations

# Interactive cluster UI
k9s

# View logs
cat /path/to/linux_installer_*.log
```

## Color-Coded Output
- **Green**: Success
- **Yellow**: Warnings
- **Red**: Errors

## Troubleshooting

### Common Issues

**Permission Denied**
```bash
# Make sure the script is executable
chmod +x linuxAIO.sh

# Don't run as root
./linuxAIO.sh  # Correct
sudo ./linuxAIO.sh  # Wrong - script will exit
```

**System Requirements Not Met**
- Ensure you have at least 16GB RAM and 4 CPU cores
- Check Ubuntu version: `lsb_release -a`
- Check kernel version: `uname -r`

**Azure Authentication Issues**
```bash
# Manual Azure CLI login if needed
az login
az account set --subscription "Your-Subscription-Name"
```

**Network Issues**
- Ensure internet connectivity for downloading packages
- Check if corporate firewall blocks Azure or Kubernetes traffic

### Getting Help

**Check script logs:**
The script provides detailed logging with timestamps. Look for error messages in red.

**Verify installation:**
After successful installation, check:
```bash
# Check K3s status
sudo systemctl status k3s

# Check kubectl access
kubectl get nodes

# Check Azure IoT Operations pods
kubectl get pods -n azure-iot-operations
```

## Post-Installation


## Troubleshooting

**Config file cluster name mismatch:**
```bash
# Ensure cluster_name matches in both files
cat linux_aio_config.json | grep cluster_name
cat edge_configs/cluster_info.json | grep cluster_name
```

**Arc proxy fails:**
```bash
# Verify cluster is Arc-enabled
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations
```

**Stale Arc registration:**
- Automatically detected and fixed by linux_installer.sh
- Use `--force-reinstall` for complete cleanup

**View logs:**
```bash
cat linux_installer_*.log
cat external_configurator_*.log
```

## Additional Resources
- [Azure IoT Operations Docs](https://learn.microsoft.com/azure/iot-operations/)
- [K3s Documentation](https://k3s.io/)
