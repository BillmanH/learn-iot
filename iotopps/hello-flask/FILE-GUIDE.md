# Flask Hello World Deployment - File Guide

## 📁 Project Structure

```
iotopps/hello-flask/
├── 🐍 Application Files
│   ├── app.py                    # Flask REST API with health endpoints
│   ├── requirements.txt          # Python dependencies (Flask)
│   └── Dockerfile                # Container definition (uses uv)
│
├── ☸️ Kubernetes Configuration
│   └── deployment.yaml           # K8s Deployment + Service (NodePort)
│
├── 🚀 Remote Deployment (Windows → Edge)
│   ├── Deploy-ToIoTEdge.ps1     # Main remote deployment script
│   ├── Deploy-Example.ps1        # Example configuration template
│   └── Check-Deployment.ps1      # Check deployment status
│
├── 📦 Local Deployment (On Edge Device)
│   ├── deploy.sh                 # Linux/Mac deployment script
│   └── deploy.bat                # Windows deployment script
│
└── 📚 Documentation
    ├── README.md                 # Complete documentation
    ├── QUICKSTART.md             # Quick start guide
    ├── REMOTE-DEPLOY.md          # Remote deployment guide
    ├── REMOTE-QUICK-REF.md       # Quick reference card
    └── FILE-GUIDE.md             # This file
```

## 🎯 Which File Do I Use?

### For Remote Deployment (Windows → IoT Edge)

**1. First Time Setup**
```powershell
# Edit this file with your registry name
notepad Deploy-Example.ps1

# Then run it
.\Deploy-Example.ps1
```

**2. Quick Deployments**
```powershell
# One command - reads config automatically
.\Deploy-ToIoTEdge.ps1 -RegistryName "your-username"
```

**3. Check Status**
```powershell
.\Check-Deployment.ps1
```

**4. Documentation**
- Start with: `REMOTE-QUICK-REF.md`
- Full guide: `REMOTE-DEPLOY.md`

### For Local Deployment (On Edge Device)

**1. Configure**
```bash
# Edit the script
nano deploy.sh  # or deploy.bat on Windows
```

**2. Deploy**
```bash
./deploy.sh  # or deploy.bat on Windows
```

**3. Documentation**
- Start with: `QUICKSTART.md`
- Full guide: `README.md`

## 📝 File Descriptions

### Application Files

#### `app.py`
- Simple Flask REST API
- Endpoints: `/` (hello) and `/health` (health check)
- Returns JSON with timestamp and hostname
- Runs on port 5000 inside container

#### `requirements.txt`
- Flask 3.0.0
- Werkzeug 3.0.1
- Installed using `uv` (fast Python package manager)

#### `Dockerfile`
- Python 3.11 slim base
- Uses `uv` for dependency installation (10-100x faster than pip)
- Exposes port 5000
- Optimized for edge devices

### Kubernetes Configuration

#### `deployment.yaml`
- **Deployment**: 1 replica, 64-128Mi RAM, 0.1-0.2 CPU
- **Health Checks**: Liveness and readiness probes
- **Service**: NodePort type, exposed on port 30080
- **Note**: Replace `<YOUR_REGISTRY>` with your registry name

### Remote Deployment Scripts

#### `Deploy-ToIoTEdge.ps1` ⭐ MAIN SCRIPT
**Purpose**: Deploy from Windows to remote IoT cluster

**What it does**:
1. Reads `linux_aio_config.json` for cluster details
2. Builds Docker image
3. Pushes to registry (Docker Hub or ACR)
4. Connects to Arc-enabled cluster
5. Deploys to Kubernetes
6. Shows service URL

**Parameters**:
- `-RegistryName`: Your Docker Hub username or ACR name (REQUIRED)
- `-RegistryType`: "dockerhub" or "acr" (default: dockerhub)
- `-ImageTag`: Image version (default: latest)
- `-EdgeDeviceIP`: Direct SSH connection (optional)
- `-SkipBuild`: Use existing image (optional)

#### `Deploy-Example.ps1`
**Purpose**: Template for easy configuration

**What it does**:
- Copy this file for your environment
- Set your registry name once
- Run it anytime to deploy

#### `Check-Deployment.ps1`
**Purpose**: Verify deployment status

**What it does**:
- Connects to cluster
- Shows deployment, pods, service status
- Tests endpoint connectivity
- Shows recent logs and events

### Local Deployment Scripts

#### `deploy.sh` (Linux/Mac)
**Purpose**: Deploy from edge device

**What it does**:
1. Builds Docker image locally
2. Pushes to registry
3. Updates deployment.yaml
4. Applies to local K3s cluster
5. Shows service URL

#### `deploy.bat` (Windows)
Same as `deploy.sh` but for Windows edge devices

### Documentation Files

#### `README.md`
- Complete documentation
- All deployment methods
- Troubleshooting guide
- Architecture details
- Next steps

#### `QUICKSTART.md`
- Fast-track deployment
- Prerequisites checklist
- Step-by-step instructions
- Common issues

#### `REMOTE-DEPLOY.md`
- Remote deployment deep-dive
- Azure Arc connection methods
- Security considerations
- CI/CD integration examples

#### `REMOTE-QUICK-REF.md`
- One-page reference
- Common commands
- Quick troubleshooting
- Configuration overview

## 🔄 Typical Workflow

### First Deployment
```powershell
# 1. Ensure linux_aio_config.json is configured
notepad ..\..\..\linux_build\linux_aio_config.json

# 2. Deploy
.\Deploy-ToIoTEdge.ps1 -RegistryName "myusername"

# 3. Check status
.\Check-Deployment.ps1

# 4. Test
curl http://<edge-device-ip>:30080
```

### Making Changes
```powershell
# 1. Edit application
notepad app.py

# 2. Deploy with new version
.\Deploy-ToIoTEdge.ps1 -RegistryName "myusername" -ImageTag "v1.1"

# 3. Verify
.\Check-Deployment.ps1
```

### Quick Redeploy (no code changes)
```powershell
# Just redeploy existing image
.\Deploy-ToIoTEdge.ps1 -RegistryName "myusername" -SkipBuild
```

## 🔍 Dependencies

### Configuration File
All scripts read from:
```
../../../linux_build/linux_aio_config.json
```

This contains:
- Azure subscription ID
- Resource group name
- Cluster name
- Location

### External Requirements
- Docker (for building images)
- Azure CLI (for Arc connection)
- kubectl (for K8s operations)
- Container registry account

## 🎓 Learning Path

1. **Start Here**: `REMOTE-QUICK-REF.md` (2 min read)
2. **First Deploy**: Run `Deploy-ToIoTEdge.ps1`
3. **Verify**: Run `Check-Deployment.ps1`
4. **Deep Dive**: Read `REMOTE-DEPLOY.md`
5. **Customize**: Modify `app.py` and redeploy

## 💡 Pro Tips

1. **Use Deploy-Example.ps1**: Set your registry once, run anytime
2. **Keep ImageTags**: Use version tags (v1.0, v1.1) instead of "latest"
3. **Check First**: Run `Check-Deployment.ps1` before redeploying
4. **Watch Logs**: Use `kubectl logs -l app=hello-flask -f` to follow in real-time
5. **Test Locally**: Test Docker image locally before pushing

## ❓ Common Questions

**Q: Which deployment method should I use?**
A: Use `Deploy-ToIoTEdge.ps1` for remote deployment from Windows. It's automated and reads your cluster config.

**Q: Do I need to edit deployment.yaml?**
A: No! The scripts handle that automatically.

**Q: Where is my cluster config?**
A: In `../../../linux_build/linux_aio_config.json`

**Q: How do I update my app?**
A: Edit `app.py`, then run `Deploy-ToIoTEdge.ps1` with a new `-ImageTag`

**Q: Can I deploy multiple times?**
A: Yes! Each deployment updates the existing deployment.

## 🆘 Quick Troubleshooting

| Issue | Check | Solution |
|-------|-------|----------|
| Can't connect to cluster | `Check-Deployment.ps1` | Verify Arc connection |
| Image won't pull | Pod logs | Check registry credentials |
| Can't access URL | Firewall | Allow port 30080 |
| Pod crashes | `kubectl logs` | Check application errors |

## 📞 Next Steps

1. ✅ Deploy the app
2. 📝 Modify `app.py` to add your logic
3. 🔄 Set up automated deployments
4. 📊 Add monitoring and logging
5. 🔐 Implement security best practices
