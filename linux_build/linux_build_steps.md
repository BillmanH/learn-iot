# Azure IoT Operations Linux Installation - Quick Start Guide

This guide provides step-by-step instructions for running the `linuxAIO.sh` script on a fresh Linux installation to set up Azure IoT Operations on a K3s Kubernetes cluster.

## Prerequisites

### System Requirements
- **OS**: Ubuntu 24.04+ (recommended)
- **RAM**: Minimum 16GB (32GB recommended)
- **CPU**: Minimum 4 cores
- **Kernel**: Version 5.15+
- **User**: Non-root user with sudo privileges

### Azure Requirements
- Active Azure subscription
- Azure CLI access or ability to authenticate via browser

## Quick Setup Steps

### 1. Prepare Your Linux System

If you're on a fresh Ubuntu install, update the system first:
```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Clone or Download the Repository

If you haven't already, get the repository:
```bash
git clone <repository-url>
cd learn-iothub/linux_build
```

### 3. Configure the Installation (Optional but Recommended)

Create a configuration file to customize your deployment:

```bash
# Copy the template configuration
cp linux_aio_config.template.json linux_aio_config.json

# Edit the configuration file
nano linux_aio_config.json
```

**Minimal configuration** - Update these values:
- `subscription_id`: Your Azure subscription ID (or leave empty to use current login)
- `resource_group`: Name for your resource group (e.g., "rg-iot-demo")
- `location`: Azure region (e.g., "eastus", "westus2")
- `cluster_name`: Name for your cluster (e.g., "my-iot-cluster")

**Example configuration:**
```json
{
  "azure": {
    "subscription_id": "",
    "resource_group": "rg-iot-demo",
    "location": "eastus",
    "cluster_name": "demo-iot-cluster",
    "namespace_name": "iot-operations-ns"
  },
  "deployment": {
    "skip_system_update": false,
    "force_reinstall": false,
    "deployment_mode": "test"
  }
}
```

### 4. Make the Script Executable

```bash
chmod +x linuxAIO.sh
```

### 5. Run the Installation Script

```bash
./linuxAIO.sh
```

**What the script will do:**
1. Check system requirements
2. Load configuration from `linux_aio_config.json` (if exists)
3. Update system packages (unless skipped in config)
4. Install required tools (Azure CLI, kubectl, Helm, etc.)
5. Install and configure K3s Kubernetes
6. Set up Azure authentication
7. Create Azure resources (Resource Group, etc.)
8. Enable Azure Arc on the cluster
9. Deploy Azure IoT Operations
10. Verify the deployment

## During Installation

### Authentication
The script will prompt you to authenticate with Azure:
- If Azure CLI is not logged in, you'll see a browser authentication prompt
- Follow the on-screen instructions to complete authentication

### Monitoring Progress
The script provides colored output:
- **Green**: Normal progress messages
- **Yellow**: Warnings (installation continues)
- **Red**: Errors (installation stops)

### Estimated Time
- Fresh installation: 20-45 minutes
- Subsequent runs: 10-20 minutes (if components already installed)

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

After successful installation:

1. **Save your configuration** - Keep your `linux_aio_config.json` for future use
2. **Access your cluster** - kubectl is configured and ready to use
3. **Check Azure Portal** - Your resources will appear in the specified resource group
4. **Follow next steps** - The script will display additional configuration steps

## Re-running the Script

You can safely re-run the script:
- Existing components will be detected and skipped
- Use `force_reinstall: true` in config to reinstall components
- Use `skip_system_update: true` in config for faster subsequent runs

## Additional Resources

- Azure IoT Operations Documentation: [Microsoft Learn](https://learn.microsoft.com/azure/iot-operations/)
- K3s Documentation: [k3s.io](https://k3s.io/)
- Azure CLI Reference: [Microsoft Docs](https://docs.microsoft.com/cli/azure/)
