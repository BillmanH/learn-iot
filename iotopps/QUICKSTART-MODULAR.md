# Quick Start: Using Modular Deployment Scripts

This guide shows you how to use the new modular deployment scripts with any application.

## Prerequisites

- Windows machine with PowerShell
- Docker Desktop
- Azure CLI
- kubectl
- Access to a container registry (Docker Hub or ACR)

## Basic Usage

All scripts are located in the `iotopps` folder and work with any application.

### 1️⃣ Deploy to IoT Edge

```powershell
cd iotopps
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "your-dockerhub-username"
```

**What it does:**
- Builds Docker image in the specified app folder
- Pushes to your container registry
- Deploys to IoT Operations cluster via Azure Arc
- Shows deployment status

### 2️⃣ Test Locally

```powershell
cd iotopps
.\Deploy-Local.ps1 -AppFolder "hello-flask"
```

**What it does:**
- Auto-detects best runtime (uv → docker → python)
- Installs dependencies
- Runs application on localhost:5000
- Press Ctrl+C to stop

### 3️⃣ Check Status

```powershell
cd iotopps
.\Deploy-Check.ps1 -AppFolder "hello-flask"
```

**What it does:**
- Connects to your cluster
- Shows deployment, pod, and service status
- Tests endpoint connectivity
- Displays recent logs and events

## Common Scenarios

### Scenario: First Time Deployment

```powershell
# Step 1: Navigate to iotopps folder
cd C:\Users\YourName\repos\learn-iothub\iotopps

# Step 2: Test locally first
.\Deploy-Local.ps1 -AppFolder "hello-flask"
# Visit http://localhost:5000 in browser
# Press Ctrl+C when satisfied

# Step 3: Deploy to edge
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myusername"

# Step 4: Verify deployment
.\Deploy-Check.ps1 -AppFolder "hello-flask"
```

### Scenario: Update Existing App

```powershell
# Make your code changes in hello-flask folder...

# Redeploy with new version tag
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" `
                       -RegistryName "myusername" `
                       -ImageTag "v1.1"

# Verify new version is running
.\Deploy-Check.ps1 -AppFolder "hello-flask"
```

### Scenario: Deploy Multiple Apps

```powershell
# Deploy first app
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myusername"

# Deploy second app (if you have one)
.\Deploy-ToIoTEdge.ps1 -AppFolder "data-logger" -RegistryName "myusername"

# Deploy third app
.\Deploy-ToIoTEdge.ps1 -AppFolder "mqtt-handler" -RegistryName "myusername"

# Check all deployments
.\Deploy-Check.ps1 -AppFolder "hello-flask"
.\Deploy-Check.ps1 -AppFolder "data-logger"
.\Deploy-Check.ps1 -AppFolder "mqtt-handler"
```

### Scenario: Development with Docker

```powershell
# Force Docker mode (even if uv is available)
.\Deploy-Local.ps1 -AppFolder "hello-flask" -Mode docker

# Rebuild Docker image
.\Deploy-Local.ps1 -AppFolder "hello-flask" -Mode docker -Build

# Use custom port
.\Deploy-Local.ps1 -AppFolder "hello-flask" -Mode docker -Port 8080
```

### Scenario: Use Azure Container Registry

```powershell
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" `
                       -RegistryName "myacr" `
                       -RegistryType "acr" `
                       -ImageTag "prod-v1.0"
```

## Advanced Options

### Deploy-ToIoTEdge.ps1

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-AppFolder` | App folder name (required) | `-AppFolder "hello-flask"` |
| `-RegistryName` | Registry name (required) | `-RegistryName "myusername"` |
| `-RegistryType` | `dockerhub` or `acr` | `-RegistryType "acr"` |
| `-ImageTag` | Image version tag | `-ImageTag "v1.0"` |
| `-SkipBuild` | Use existing image | `-SkipBuild` |
| `-EdgeDeviceIP` | Direct SSH connection | `-EdgeDeviceIP "192.168.1.100"` |
| `-ConfigPath` | Custom config path | `-ConfigPath "custom.json"` |

### Deploy-Local.ps1

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-AppFolder` | App folder name (required) | `-AppFolder "hello-flask"` |
| `-Mode` | Runtime mode | `-Mode "docker"` |
| `-Port` | Local port | `-Port 8080` |
| `-Build` | Force Docker rebuild | `-Build` |
| `-Clean` | Clean Python venv | `-Clean` |

### Deploy-Check.ps1

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-AppFolder` | App folder name (required) | `-AppFolder "hello-flask"` |
| `-EdgeDeviceIP` | Direct connection | `-EdgeDeviceIP "192.168.1.100"` |
| `-ConfigPath` | Custom config path | `-ConfigPath "custom.json"` |

## Configuration Files

### App-Specific Config (Optional)

Create `{app-folder}/{app-name}_config.json` to set defaults:

```json
{
  "registry": {
    "type": "dockerhub",
    "name": "myusername"
  },
  "image": {
    "tag": "latest"
  },
  "development": {
    "localPort": 5000,
    "preferredRuntime": "auto"
  }
}
```

**Benefits:**
- Skip typing `-RegistryName` every time
- Set default ports and tags
- Share settings with team

**Example with config file:**
```powershell
# Without config: need to specify everything
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser" -ImageTag "latest"

# With config: much shorter!
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask"
```

## Troubleshooting

### Error: "Application folder not found"
**Cause:** Wrong working directory or app folder doesn't exist
**Fix:**
```powershell
# Check where you are
pwd

# Should be in iotopps folder
cd C:\Users\YourName\repos\learn-iothub\iotopps

# List available apps
dir
```

### Error: "Dockerfile not found"
**Cause:** App folder missing required files
**Fix:** Ensure your app has:
- `Dockerfile`
- `deployment.yaml`
- Application code

### Error: "Registry name is required"
**Cause:** No registry specified and no config file
**Fix:** Either:
- Add `-RegistryName "yourname"` to command
- Create app config file with registry name

### Error: "Cannot connect to cluster"
**Cause:** Cluster proxy not started or Azure CLI not authenticated
**Fix:**
```powershell
# Login to Azure
az login

# Verify cluster exists
az connectedk8s list

# Try deployment again
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser"
```

## Tips and Best Practices

### 1. Always test locally first
```powershell
.\Deploy-Local.ps1 -AppFolder "hello-flask"
# Test thoroughly, then deploy
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser"
```

### 2. Use version tags
```powershell
# Good: versioned deployments
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser" -ImageTag "v1.0"
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser" -ImageTag "v1.1"

# Avoid: always using 'latest' (hard to track)
```

### 3. Create app config files
Saves time and prevents typos:
```json
{
  "registry": {
    "type": "dockerhub",
    "name": "myusername"
  }
}
```

### 4. Check status after deployment
```powershell
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser"
# Wait a moment...
.\Deploy-Check.ps1 -AppFolder "hello-flask"
```

### 5. Use `-SkipBuild` for faster iterations
```powershell
# First deploy: full build
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser"

# Only changed deployment.yaml? Skip rebuild
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myuser" -SkipBuild
```

## Quick Reference Card

```powershell
# 🏠 LOCAL DEVELOPMENT
.\Deploy-Local.ps1 -AppFolder "app-name"

# 🚀 DEPLOY TO EDGE
.\Deploy-ToIoTEdge.ps1 -AppFolder "app-name" -RegistryName "username"

# 🔍 CHECK STATUS
.\Deploy-Check.ps1 -AppFolder "app-name"

# 🐳 DOCKER MODE
.\Deploy-Local.ps1 -AppFolder "app-name" -Mode docker

# 🏷️ VERSIONED DEPLOY
.\Deploy-ToIoTEdge.ps1 -AppFolder "app-name" -RegistryName "username" -ImageTag "v1.0"

# ⚡ SKIP BUILD
.\Deploy-ToIoTEdge.ps1 -AppFolder "app-name" -RegistryName "username" -SkipBuild
```

## Next Steps

1. ✅ Try deploying hello-flask
2. ✅ Create your own app folder
3. ✅ Deploy your custom app
4. ✅ Share your app config with your team

For more details, see:
- [Full README](README.md) - Complete documentation
- [Migration Guide](MIGRATION-GUIDE.md) - Migrating from old scripts
- [hello-flask README](hello-flask/README.md) - Example app details
