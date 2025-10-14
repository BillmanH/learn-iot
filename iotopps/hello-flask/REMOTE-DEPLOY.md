# Remote IoT Edge Deployment Guide

This guide explains how to deploy the Flask application from your Windows machine to a remote Azure IoT Operations cluster.

## Overview

The `Deploy-ToIoTEdge.ps1` script automates the entire deployment process:
1. Reads cluster configuration from `linux_aio_config.json`
2. Builds and pushes the Docker image to your registry
3. Connects to your Arc-enabled K3s cluster
4. Deploys the application to the edge device

## Prerequisites

### On Your Windows Machine
- PowerShell 5.1 or later
- Docker Desktop installed and running
- Azure CLI (`az`) installed
- kubectl installed
- Docker Hub account or Azure Container Registry access

### On Your Edge Device
- Azure IoT Operations installed (via `linuxAIO.sh`)
- K3s cluster running
- Connected to Azure Arc
- SSH access enabled (optional, for direct connection)

## Configuration

### 1. Update `linux_aio_config.json`

Ensure your `linux_build\linux_aio_config.json` contains your cluster details:

```json
{
  "azure": {
    "subscription_id": "your-subscription-id",
    "resource_group": "IoT-Operations-Edge",
    "location": "eastus",
    "cluster_name": "my-iot-cluster",
    "namespace_name": "iot-operations-ns"
  }
}
```

## Deployment Methods

### Method 1: Via Azure Arc (Recommended)

This method uses Azure Arc to connect to your cluster without direct network access.

```powershell
cd iotopps\hello-flask

# Deploy with Docker Hub
.\Deploy-ToIoTEdge.ps1 -RegistryName "your-dockerhub-username"

# Deploy with Azure Container Registry
.\Deploy-ToIoTEdge.ps1 -RegistryName "myacr" -RegistryType "acr"

# Deploy with specific tag
.\Deploy-ToIoTEdge.ps1 -RegistryName "your-username" -ImageTag "v1.0"
```

### Method 2: Direct Connection to Edge Device

If you have direct network access to your edge device:

```powershell
.\Deploy-ToIoTEdge.ps1 `
    -RegistryName "your-username" `
    -EdgeDeviceIP "192.168.1.100" `
    -EdgeDeviceUser "azureuser"
```

## Script Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `RegistryName` | Yes | - | Your Docker Hub username or ACR name |
| `RegistryType` | No | `dockerhub` | Registry type: `dockerhub` or `acr` |
| `ImageTag` | No | `latest` | Docker image tag |
| `ConfigPath` | No | `../../../linux_build/linux_aio_config.json` | Path to config file |
| `EdgeDeviceIP` | No | - | IP address of edge device for direct SSH access |
| `EdgeDeviceUser` | No | `azureuser` | SSH username for edge device |
| `SkipBuild` | No | `false` | Skip building/pushing image (use existing) |

## Usage Examples

### First Deployment
```powershell
# Build, push, and deploy everything
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe"
```

### Update Application Code
```powershell
# After modifying app.py, deploy with new version
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe" -ImageTag "v1.1"
```

### Redeploy Existing Image
```powershell
# Deploy without rebuilding (faster)
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe" -SkipBuild
```

### Deploy to Specific Edge Device
```powershell
# Direct deployment via SSH
.\Deploy-ToIoTEdge.ps1 `
    -RegistryName "johndoe" `
    -EdgeDeviceIP "10.0.0.50" `
    -EdgeDeviceUser "admin"
```

## What the Script Does

1. **Loads Configuration**: Reads cluster details from `linux_aio_config.json`
2. **Validates Prerequisites**: Checks for Docker, kubectl, and Azure CLI
3. **Builds Docker Image**: Creates container with your Flask app (using `uv`)
4. **Pushes to Registry**: Uploads image to Docker Hub or ACR
5. **Connects to Cluster**: Uses Azure Arc proxy or direct SSH
6. **Deploys Application**: Applies Kubernetes manifests
7. **Verifies Deployment**: Waits for pods to be ready
8. **Displays Results**: Shows service URL and useful commands

## Troubleshooting

### "Configuration file not found"
Ensure `linux_build\linux_aio_config.json` exists with your cluster configuration.

### "Docker build failed"
- Check that Docker Desktop is running
- Verify you're in the `iotopps\hello-flask` directory
- Check `Dockerfile` syntax

### "Cannot connect to cluster"
**Via Arc:**
- Verify Arc connection: `az connectedk8s show -n <cluster-name> -g <resource-group>`
- Check RBAC permissions: You need read/write access to the cluster
- Ensure Arc agents are running on the edge device

**Direct SSH:**
- Verify SSH access: `ssh azureuser@<edge-device-ip>`
- Check K3s is running: `sudo systemctl status k3s`
- Verify firewall allows port 6443

### "ImagePullBackOff" in Kubernetes
The cluster can't pull your image. For private registries:

```powershell
# Create registry secret on cluster
kubectl create secret docker-registry regcred `
  --docker-server=docker.io `
  --docker-username=<username> `
  --docker-password=<password>

# Add to deployment.yaml:
# imagePullSecrets:
# - name: regcred
```

### "Deployment status check timed out"
Check pod status manually:
```powershell
kubectl get pods -l app=hello-flask
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

## Verifying Deployment

After successful deployment, verify with:

```powershell
# Check pods are running
kubectl get pods -l app=hello-flask

# Check service
kubectl get service hello-flask-service

# View logs
kubectl logs -l app=hello-flask

# Get full deployment status
kubectl describe deployment hello-flask
```

## Accessing Your Application

The script will display the service URL. Test it:

```powershell
# From your Windows machine (if network allows)
curl http://<edge-device-ip>:30080
curl http://<edge-device-ip>:30080/health

# Or use browser
Start-Process "http://<edge-device-ip>:30080"
```

From any device on the same network as the edge device:
```
http://<edge-device-ip>:30080
```

## Updating Your Application

1. Modify `app.py` with your changes
2. Run deployment script with new tag:
   ```powershell
   .\Deploy-ToIoTEdge.ps1 -RegistryName "your-username" -ImageTag "v1.1"
   ```
3. Script will build, push, and update the deployment automatically

## Cleanup

To remove the application from your cluster:

```powershell
kubectl delete -f deployment.yaml
```

To remove the Docker image from your registry:
```powershell
# Docker Hub - use web interface or API
# ACR
az acr repository delete --name <acr-name> --image hello-flask:latest
```

## Security Considerations

### For Production Deployments:
1. **Use Azure Container Registry** instead of public Docker Hub
2. **Enable RBAC** on your K3s cluster
3. **Use Kubernetes secrets** for sensitive data
4. **Configure network policies** to restrict traffic
5. **Enable TLS/HTTPS** with proper certificates
6. **Use private container registries** with authentication
7. **Implement Pod Security Standards**

### Registry Authentication:
```powershell
# For private registries, create secret before deploying
kubectl create secret docker-registry regcred `
  --docker-server=<registry-url> `
  --docker-username=<username> `
  --docker-password=<password> `
  --docker-email=<email>
```

## Integration with CI/CD

You can integrate this script into your CI/CD pipeline:

### Azure DevOps Pipeline Example:
```yaml
steps:
- task: PowerShell@2
  inputs:
    filePath: 'iotopps/hello-flask/Deploy-ToIoTEdge.ps1'
    arguments: '-RegistryName $(REGISTRY_NAME) -ImageTag $(Build.BuildId)'
```

### GitHub Actions Example:
```yaml
- name: Deploy to IoT Edge
  shell: pwsh
  run: |
    .\iotopps\hello-flask\Deploy-ToIoTEdge.ps1 `
      -RegistryName ${{ secrets.REGISTRY_NAME }} `
      -ImageTag ${{ github.sha }}
```

## Next Steps

- Set up automated deployments with CI/CD
- Add monitoring with Application Insights
- Implement MQTT integration with IoT Operations broker
- Configure persistent storage for application data
- Set up alerts and notifications
- Implement blue-green or canary deployments

## Related Documentation

- [Main README](README.md) - Complete application documentation
- [QUICKSTART](QUICKSTART.md) - Quick deployment guide
- [Linux Build Steps](../../linux_build/linux_build_steps.md) - IoT Operations setup
- [K3s Troubleshooting](../../linux_build/K3S_TROUBLESHOOTING_GUIDE.md) - Cluster issues
