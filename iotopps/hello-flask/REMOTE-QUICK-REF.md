# Remote Deployment - Quick Reference

## One-Command Deployment

From your Windows machine in the `iotopps/hello-flask` directory:

```powershell
# Deploy to remote IoT cluster (via Azure Arc)
.\Deploy-ToIoTEdge.ps1 -RegistryName "your-username"
```

That's it! The script will:
1. ✓ Read cluster config from `linux_build/linux_aio_config.json`
2. ✓ Build Docker image using `uv`
3. ✓ Push to your registry
4. ✓ Connect to your Arc-enabled cluster
5. ✓ Deploy the Flask app
6. ✓ Show you the service URL

## Common Scenarios

### First Time Deployment
```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe"
```

### Deploy New Version
```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe" -ImageTag "v1.1"
```

### Use Azure Container Registry
```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "myacr" -RegistryType "acr"
```

### Direct Connection (if you have network access)
```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe" -EdgeDeviceIP "192.168.1.100"
```

### Redeploy Without Rebuilding
```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "johndoe" -SkipBuild
```

## Configuration File

Your cluster configuration is in `linux_build/linux_aio_config.json`:

```json
{
  "azure": {
    "subscription_id": "your-sub-id",
    "resource_group": "IoT-Operations-Edge",
    "cluster_name": "my-iot-cluster",
    "location": "eastus"
  }
}
```

The script reads this automatically - no need to pass cluster details!

## Troubleshooting One-Liners

```powershell
# Check cluster connection
az connectedk8s show -n <cluster-name> -g <resource-group>

# View pods
kubectl get pods -l app=hello-flask

# View logs
kubectl logs -l app=hello-flask

# Check service
kubectl get service hello-flask-service

# Test the app
curl http://<edge-device-ip>:30080
```

## Directory Structure
```
learn-iothub/
├── linux_build/
│   └── linux_aio_config.json       # ← Your cluster config here
└── iotopps/
    └── hello-flask/
        ├── Deploy-ToIoTEdge.ps1    # ← Main deployment script
        ├── Deploy-Example.ps1       # ← Copy & customize this
        ├── app.py                   # ← Your Flask app
        ├── Dockerfile               # ← Using uv for deps
        └── deployment.yaml          # ← K8s manifest
```

## Need More Details?

- **Complete guide**: [REMOTE-DEPLOY.md](REMOTE-DEPLOY.md)
- **App documentation**: [README.md](README.md)
- **Local deployment**: [QUICKSTART.md](QUICKSTART.md)
