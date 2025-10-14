# Flask Hello World - IoT Edge Deployment

This is a simple Flask application designed to be deployed to your Azure IoT Operations Kubernetes cluster on an edge device.

## 🚀 Quick Start - Choose Your Method

### Method 1: Remote Deployment (Recommended for Windows)
Deploy from your Windows machine to a remote IoT Operations cluster:

```powershell
.\Deploy-ToIoTEdge.ps1 -RegistryName "your-dockerhub-username"
```

**📖 See [REMOTE-QUICK-REF.md](REMOTE-QUICK-REF.md) for one-command deployment**  
**📚 See [REMOTE-DEPLOY.md](REMOTE-DEPLOY.md) for complete remote deployment guide**

### Method 2: Local Deployment
Deploy directly on the edge device (Linux/Mac):

```bash
./deploy.sh  # After configuring registry name
```

**📖 See [QUICKSTART.md](QUICKSTART.md) for step-by-step local deployment**

## Quick Start

### Prerequisites
- Docker installed locally (for building the image)
- Access to a container registry (Docker Hub, Azure Container Registry, etc.)
- Azure IoT Operations running on your K3s cluster
- kubectl configured to access your cluster

**Note**: This application uses `uv` for fast, reliable Python dependency management in the Docker container.

## Deployment Steps

### 1. Build the Docker Image

The Dockerfile uses `uv` for fast dependency installation:

```bash
cd iotopps/hello-flask
docker build -t hello-flask:latest .
```

### 2. Tag and Push to Your Container Registry

#### For Docker Hub:
```bash
# Tag the image
docker tag hello-flask:latest <your-dockerhub-username>/hello-flask:latest

# Login to Docker Hub
docker login

# Push the image
docker push <your-dockerhub-username>/hello-flask:latest
```

#### For Azure Container Registry (ACR):
```bash
# Login to ACR
az acr login --name <your-acr-name>

# Tag the image
docker tag hello-flask:latest <your-acr-name>.azurecr.io/hello-flask:latest

# Push the image
docker push <your-acr-name>.azurecr.io/hello-flask:latest
```

### 3. Update Deployment Configuration

Edit `deployment.yaml` and replace `<YOUR_REGISTRY>` with your actual registry path:
- Docker Hub: `<your-dockerhub-username>/hello-flask:latest`
- ACR: `<your-acr-name>.azurecr.io/hello-flask:latest`

### 4. Deploy to K3s Cluster

```bash
# Apply the deployment
kubectl apply -f deployment.yaml

# Check deployment status
kubectl get deployments
kubectl get pods
kubectl get services
```

### 5. Access Your Application

Once deployed, the application will be accessible on your edge device's local network:

```
http://<edge-device-ip>:30080
```

To find your edge device's IP:
```bash
hostname -I
```

## Testing the Application

### Health Check
```bash
curl http://<edge-device-ip>:30080/health
```

### Main Endpoint
```bash
curl http://<edge-device-ip>:30080/
```

Expected response:
```json
{
  "message": "Hello from IoT Edge!",
  "timestamp": "2025-10-14T12:34:56.789",
  "hostname": "hello-flask-xxxxx-xxxxx",
  "version": "1.0.0"
}
```

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods -l app=hello-flask
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

### Check Service
```bash
kubectl get service hello-flask-service
kubectl describe service hello-flask-service
```

### Check Node Port
```bash
# Verify the service is listening on port 30080
sudo netstat -tulpn | grep 30080
```

### Common Issues

1. **ImagePullBackOff**: Check that your registry credentials are configured correctly
   ```bash
   # For private registries, create a secret:
   kubectl create secret docker-registry regcred \
     --docker-server=<your-registry> \
     --docker-username=<username> \
     --docker-password=<password>
   
   # Then add to deployment.yaml under spec.template.spec:
   # imagePullSecrets:
   # - name: regcred
   ```

2. **CrashLoopBackOff**: Check pod logs for errors
   ```bash
   kubectl logs <pod-name>
   ```

3. **Can't access from network**: Verify firewall rules allow port 30080
   ```bash
   sudo ufw allow 30080/tcp
   ```

## Updating the Application

1. Make changes to `app.py`
2. Rebuild the image with a new tag:
   ```bash
   docker build -t hello-flask:v2 .
   docker tag hello-flask:v2 <your-registry>/hello-flask:v2
   docker push <your-registry>/hello-flask:v2
   ```
3. Update `deployment.yaml` to use the new image tag
4. Reapply the deployment:
   ```bash
   kubectl apply -f deployment.yaml
   kubectl rollout status deployment/hello-flask
   ```

## Cleanup

To remove the application:
```bash
kubectl delete -f deployment.yaml
```

## Architecture

- **Flask App**: Simple REST API with health check endpoint
- **Package Manager**: Uses `uv` for fast, reliable dependency installation
- **Service Type**: NodePort (accessible on local network)
- **Port**: 30080 (external), 5000 (internal container)
- **Resources**: Minimal footprint for edge devices (64Mi-128Mi RAM, 0.1-0.2 CPU)
- **Health Checks**: Liveness and readiness probes for reliability

## Technology Stack

- **Python**: 3.11-slim base image for small container size
- **Package Manager**: `uv` - modern, fast Python package installer
- **Web Framework**: Flask 3.0.0
- **Container Runtime**: Docker
- **Orchestration**: Kubernetes (K3s)
- **Deployment**: Azure IoT Operations

## Next Steps

- Add environment-specific configurations using ConfigMaps
- Implement MQTT integration with Azure IoT Operations broker
- Add persistent storage for logging or data
- Set up monitoring and alerts
- Integrate with Azure IoT Hub for cloud connectivity
