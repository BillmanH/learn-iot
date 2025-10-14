# IoT Operations Applications

This directory contains containerized applications designed to be deployed to Azure IoT Operations (AIO) Kubernetes clusters running on edge devices.

## Available Applications

### 📦 hello-flask
A simple Flask "Hello World" REST API that demonstrates:
- Container deployment to IoT Operations
- Remote deployment from Windows to edge devices
- Using `uv` for Python dependency management
- Kubernetes service exposure on local networks
- Health checks and monitoring

**Quick Deploy:** `cd hello-flask && .\Deploy-ToIoTEdge.ps1 -RegistryName "your-username"`

[📖 Read the docs →](./hello-flask/README.md)

## Deployment Workflows

### Remote Deployment (Windows → Edge Device)
Deploy applications from your Windows development machine to remote IoT Operations clusters:

1. Configure your cluster in `../../linux_build/linux_aio_config.json`
2. Navigate to the application directory (e.g., `cd hello-flask`)
3. Run the deployment script: `.\Deploy-ToIoTEdge.ps1 -RegistryName "your-registry"`

The script handles:
- ✓ Building Docker images
- ✓ Pushing to container registry
- ✓ Connecting to Arc-enabled clusters
- ✓ Deploying to Kubernetes
- ✓ Verifying deployment status

### Local Deployment (On Edge Device)
Deploy directly from the edge device:

1. Navigate to the application directory
2. Run the deployment script: `./deploy.sh` (Linux/Mac) or `deploy.bat` (Windows)

## Prerequisites

### For Remote Deployment
- Docker Desktop (Windows/Mac)
- Azure CLI (`az`)
- kubectl
- Access to container registry (Docker Hub or ACR)
- Azure IoT Operations deployed and Arc-connected

### For Local Deployment
- Docker installed on edge device
- kubectl configured for local K3s
- Access to container registry

## Project Structure

```
iotopps/
├── README.md                    # This file
├── .vscode/
│   └── settings.json           # VS Code settings (uses uv for Python)
└── hello-flask/                # Flask Hello World app
    ├── app.py                  # Flask application
    ├── Dockerfile              # Container definition (uses uv)
    ├── requirements.txt        # Python dependencies
    ├── deployment.yaml         # Kubernetes manifest
    ├── Deploy-ToIoTEdge.ps1   # Remote deployment script
    ├── Deploy-Example.ps1      # Example configuration
    ├── Check-Deployment.ps1    # Status checker
    ├── deploy.sh               # Local deployment (Linux/Mac)
    ├── deploy.bat              # Local deployment (Windows)
    ├── README.md               # Full documentation
    ├── QUICKSTART.md           # Quick start guide
    ├── REMOTE-DEPLOY.md        # Remote deployment guide
    └── REMOTE-QUICK-REF.md     # Quick reference card
```

## Configuration

Your IoT Operations cluster configuration is stored in:
```
../../linux_build/linux_aio_config.json
```

This file contains:
- Azure subscription details
- Resource group name
- Cluster name and location
- Deployment preferences

All deployment scripts automatically read this configuration.

## Common Commands

### Check Application Status
```powershell
cd hello-flask
.\Check-Deployment.ps1
```

### View Application Logs
```bash
kubectl logs -l app=hello-flask
```

### Access Applications
Applications are exposed via NodePort on the edge device's network:
```
http://<edge-device-ip>:30080
```

### Update Application
1. Modify source code
2. Run deployment script with new tag:
   ```powershell
   .\Deploy-ToIoTEdge.ps1 -RegistryName "your-username" -ImageTag "v1.1"
   ```

## Adding New Applications

To add a new application to this directory:

1. Create a new folder: `iotopps/your-app-name/`
2. Add your application code and Dockerfile
3. Create `deployment.yaml` for Kubernetes
4. Copy and adapt deployment scripts from `hello-flask/`
5. Update this README with your application

## Technology Stack

- **Container Runtime**: Docker
- **Orchestration**: Kubernetes (K3s)
- **Python Package Manager**: `uv` (fast, modern)
- **Edge Platform**: Azure IoT Operations
- **Cloud Integration**: Azure Arc

## Related Documentation

- [Linux Build Steps](../../linux_build/linux_build_steps.md) - Setting up IoT Operations
- [K3s Troubleshooting](../../linux_build/K3S_TROUBLESHOOTING_GUIDE.md) - Cluster issues
- [Project README](../../readme.md) - Overall project documentation

## Next Steps

- ✅ Deploy your first application (hello-flask)
- 🔄 Integrate with MQTT broker for IoT messaging
- 📊 Add monitoring and observability
- 🔒 Implement security best practices
- 🚀 Set up CI/CD pipelines
- 📦 Create additional applications

## Support

For issues or questions:
1. Check application-specific README files
2. Review troubleshooting guides in `linux_build/`
3. Check Azure IoT Operations documentation
4. Review Kubernetes logs and events
