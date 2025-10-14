# Quick Deployment Guide

This guide provides the fastest path to deploy the Flask hello world app to your IoT Edge device.

## Choose Your Deployment Method

### 🚀 Remote Deployment (Windows → Remote Edge Device)
**Use this if you want to deploy from your Windows machine to a remote IoT Operations cluster**

See [REMOTE-DEPLOY.md](REMOTE-DEPLOY.md) for complete guide.

**Quick command:**
```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "your-dockerhub-username"
```

This script:
- Reads cluster config from `linux_aio_config.json`
- Builds and pushes Docker image
- Connects via Azure Arc
- Deploys to your remote edge device
- Shows you the service URL

---

### 📦 Local Deployment (On the Edge Device)
**Use this if you're working directly on the edge device**

Continue with the steps below for manual deployment.

## Prerequisites Check

Before starting, ensure you have:
- [ ] Docker installed and running
- [ ] kubectl installed and configured to access your K3s cluster
- [ ] A container registry account (Docker Hub or Azure Container Registry)
- [ ] Azure IoT Operations running on your edge device

## Step-by-Step Deployment

### 1. Configure the Deployment Script

Edit the deployment script for your platform:

**Linux/Mac (`deploy.sh`):**
```bash
REGISTRY_TYPE="dockerhub"  # or "acr" for Azure Container Registry
REGISTRY_NAME="your-username"  # Your Docker Hub username or ACR name
```

**Windows (`deploy.bat`):**
```batch
set REGISTRY_TYPE=dockerhub
set REGISTRY_NAME=your-username
```

### 2. Make Script Executable (Linux/Mac only)
```bash
chmod +x deploy.sh
```

### 3. Run the Deployment

**Linux/Mac:**
```bash
./deploy.sh
```

**Windows:**
```batch
deploy.bat
```

The script will:
1. Build the Docker image
2. Tag it with your registry name
3. Login to your registry (you'll be prompted for credentials)
4. Push the image to the registry
5. Deploy to your K3s cluster
6. Wait for the deployment to be ready
7. Display the URL to access your app

### 4. Access Your Application

After deployment completes, the script will show you the URL:
```
http://<your-edge-device-ip>:30080
```

Test it:
```bash
curl http://<your-edge-device-ip>:30080
```

## Manual Deployment (Alternative)

If you prefer to run commands manually or troubleshoot:

### 1. Build the image
```bash
cd iotopps/hello-flask
docker build -t hello-flask:latest .
```

### 2. Tag for your registry

**Docker Hub:**
```bash
docker tag hello-flask:latest your-username/hello-flask:latest
```

**Azure Container Registry:**
```bash
docker tag hello-flask:latest your-acr-name.azurecr.io/hello-flask:latest
```

### 3. Login and push

**Docker Hub:**
```bash
docker login
docker push your-username/hello-flask:latest
```

**Azure Container Registry:**
```bash
az acr login --name your-acr-name
docker push your-acr-name.azurecr.io/hello-flask:latest
```

### 4. Update deployment.yaml

Replace `<YOUR_REGISTRY>` with your actual registry path:
- Docker Hub: `your-username/hello-flask:latest`
- ACR: `your-acr-name.azurecr.io/hello-flask:latest`

### 5. Deploy to K3s
```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/hello-flask
```

## Verification

Check deployment status:
```bash
# Check pods
kubectl get pods -l app=hello-flask

# Check service
kubectl get service hello-flask-service

# View logs
kubectl logs -l app=hello-flask
```

## Troubleshooting

### Can't push to registry
- **Docker Hub**: Make sure you've run `docker login` and entered correct credentials
- **ACR**: Ensure you're logged into Azure (`az login`) and have permissions to the ACR

### ImagePullBackOff error
Your cluster can't pull the image. For private registries:
```bash
# Create registry secret
kubectl create secret docker-registry regcred \
  --docker-server=<your-registry> \
  --docker-username=<username> \
  --docker-password=<password>

# Add to deployment.yaml under spec.template.spec:
# imagePullSecrets:
# - name: regcred
```

Then reapply:
```bash
kubectl apply -f deployment.yaml
```

### Can't access from browser/curl
1. Check if pod is running: `kubectl get pods -l app=hello-flask`
2. Check if service exists: `kubectl get service hello-flask-service`
3. Verify firewall allows port 30080: `sudo ufw allow 30080/tcp` (Linux)
4. Get correct node IP: `kubectl get nodes -o wide`

### Pod crashes
View logs to see the error:
```bash
kubectl logs -l app=hello-flask
kubectl describe pod <pod-name>
```

## Next Steps

Once your app is running:
- Access it from any device on your local network at `http://<edge-device-ip>:30080`
- Modify `app.py` to add new endpoints
- Integrate with MQTT broker for IoT messaging
- Add data processing logic for edge analytics

For more details, see the full [README.md](README.md).
