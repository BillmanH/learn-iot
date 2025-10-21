# IoT Edge GitHub Actions Workflows

This directory contains GitHub Actions workflows for building, testing, and deploying IoT Edge applications to Azure Arc-enabled Kubernetes clusters.

## Workflows Overview

### 1. Build and Test (`build-test.yaml`)
**Triggers:**
- Pull requests to `main` or `dev` branches (when `iotopps/**` files change)
- Manual workflow dispatch

**Purpose:**
- Validates Docker builds for changed applications
- Tests Docker images
- Validates Kubernetes manifests
- Checks for required files
- Provides feedback on PRs

**Use Cases:**
- Pre-merge validation
- Testing changes before deployment
- Continuous integration for all IoT applications

### 2. Deploy IoT Edge Application (`deploy-iot-edge.yaml`)
**Triggers:**
- Manual workflow dispatch (with app selection)
- Push to `main` or `dev` branches (auto-detects changed apps)

**Purpose:**
- Builds and pushes Docker images to registry
- Connects to Arc-enabled Kubernetes cluster
- Deploys applications using Kubernetes manifests
- Verifies deployment success
- Provides deployment summary

**Workflow Steps:**
1. Detect changed applications (on push) or use selected app (manual)
2. Build Docker image with proper tagging
3. Push image to Docker Hub or Azure Container Registry
4. Authenticate with Azure and Arc cluster
5. Apply Kubernetes deployment manifest
6. Wait for rollout completion
7. Verify pods and services
8. Report status

### 3. (Removed) Cleanup Deployment
The cleanup workflow has been removed by request. Cleanup should be done manually or via ad-hoc scripts.

## Setup Instructions

### Prerequisites

1. **Azure Resources:**
   - Azure subscription
   - Arc-enabled Kubernetes cluster
   - Container registry (Docker Hub or Azure Container Registry)

2. **GitHub Configuration:**
   - Repository secrets configured
   - Repository variables set
   - Proper permissions enabled

### Configuration Steps

Follow the detailed setup guide in **[GITHUB_SECRETS_SETUP.md](./GITHUB_SECRETS_SETUP.md)** to configure:

1. Azure authentication credentials
2. Container registry credentials  
3. Cluster connection details
4. Environment variables

**Quick Setup Checklist:**
- [ ] Create Azure service principal
- [ ] Add `AZURE_CREDENTIALS` secret
- [ ] Add `AZURE_SUBSCRIPTION_ID` secret
- [ ] Add registry credentials (Docker Hub or ACR)
- [ ] Set `AZURE_RESOURCE_GROUP` variable
- [ ] Set `AZURE_CLUSTER_NAME` variable
- [ ] Set `REGISTRY_TYPE` variable (`dockerhub` or `acr`)
- [ ] Set `REGISTRY_NAME` variable

## Usage

### Building and Testing (PR Workflow)

When you create a pull request that modifies files in `iotopps/`:

1. The workflow automatically detects changed applications
2. Builds Docker images for changed apps
3. Validates Kubernetes manifests
4. Comments on the PR with results

**No manual action required!**

### Deploying Applications

#### Option 1: Automatic Deployment (Push to Main/Dev)

When you merge to `main` or `dev` branch:

1. Changed applications are automatically detected
2. Images are built and pushed
3. Applications are deployed to the cluster

#### Option 2: Manual Deployment

1. Go to **Actions** tab in GitHub
2. Select "Deploy IoT Edge Application"
3. Click "Run workflow"
4. Choose:
   - Application (`hello-flask`, `sputnik`, etc.)
   - Image tag (default: commit SHA)
   - Environment (`development` or `production`)
   - Whether to skip build (if image exists)
5. Click "Run workflow"

### Cleaning Up Deployments

Cleanup is now a manual process. Use the Azure CLI or kubectl to remove resources, for example:

```bash
# Delete a deployment
kubectl delete deployment hello-flask --ignore-not-found
# Delete the service
kubectl delete service hello-flask-service --ignore-not-found
```

## Workflow Features

### Intelligent Application Detection

The workflows automatically detect which applications have changed:

```yaml
# Detects changes in iotopps/ directory
# Only builds/deploys apps with actual changes
# Filters to directories with Dockerfile
```

### Docker Image Tagging Strategy

- **Manual runs:** Use specified tag or commit SHA
- **PR builds:** Uses `test` tag
- **Push to main/dev:** Uses commit SHA
- **Latest tag:** Always updated alongside versioned tag

### Build Caching

Workflows use GitHub Actions cache to speed up builds:
- Docker layer caching
- Reuses unchanged layers
- Significantly faster subsequent builds

### Matrix Builds

Multiple applications can be built/deployed in parallel:
```yaml
strategy:
  matrix:
    app: [hello-flask, sputnik]
  fail-fast: false  # Continue even if one app fails
```

### Arc Cluster Connection

Workflows use Azure Arc proxy for secure cluster access:
- No direct network access required
- Works through Azure control plane
- Handles authentication automatically

## Monitoring and Debugging

### Viewing Workflow Runs

1. Go to **Actions** tab
2. Select the workflow
3. Click on a specific run
4. View logs for each step

### Common Issues and Solutions

#### Authentication Failures

**Symptoms:** Azure login fails or kubectl cannot connect

**Solutions:**
- Verify `AZURE_CREDENTIALS` secret is valid
- Check service principal hasn't expired
- Ensure proper RBAC permissions on cluster

#### Image Push Failures

**Symptoms:** Docker push fails or times out

**Solutions:**
- Verify registry credentials are correct
- Check registry name format (no `.azurecr.io` suffix for ACR)
- Ensure sufficient registry storage quota

#### Deployment Timeouts

**Symptoms:** `kubectl rollout status` times out

**Solutions:**
- Check image can be pulled: `kubectl describe pod <pod-name>`
- Verify resource limits are appropriate
- Check cluster has sufficient resources
- Review pod logs: `kubectl logs <pod-name>`

#### Proxy Connection Issues

**Symptoms:** Cannot connect to Arc cluster

**Solutions:**
- Verify cluster is connected: `az connectedk8s show`
- Check Arc agent is running on cluster
- Ensure service principal has proper permissions

### Debugging Tips

1. **Enable debug logging:**
   ```yaml
   - name: Debug step
     run: |
       set -x  # Enable verbose output
       your-command
   ```

2. **Add manual approval:**
   Use GitHub Environments with protection rules

3. **Check cluster state:**
   ```bash
   kubectl get all
   kubectl describe deployment <app-name>
   kubectl logs -l app=<app-name>
   ```

## Advanced Usage

### Custom Environments

Set up multiple environments (dev, staging, prod):

1. Create environment in GitHub Settings
2. Configure environment-specific variables
3. Add protection rules (approvers, wait time)
4. Select environment when running workflow

### Scheduled Deployments

Add a schedule trigger for regular deployments:

```yaml
on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM UTC
```

### Rollback Strategy

To rollback a deployment:

1. Use "Cleanup" workflow to remove current deployment
2. Use "Deploy" workflow with specific older image tag
3. Or use kubectl directly:
   ```bash
   kubectl rollout undo deployment/<app-name>
   ```

### Multi-Cluster Deployment

To deploy to multiple clusters:

1. Create separate environments for each cluster
2. Configure cluster-specific variables
3. Run workflow multiple times with different environments

## Security Best Practices

1. **Secrets Management:**
   - Never commit secrets to repository
   - Rotate secrets regularly (every 90 days)
   - Use GitHub Environments for sensitive deployments

2. **Service Principal:**
   - Use minimal required permissions
   - Create separate service principals per environment
   - Enable conditional access policies

3. **Image Security:**
   - Scan images for vulnerabilities
   - Use specific image tags (not `latest`)
   - Keep base images updated

4. **Access Control:**
   - Require reviews for production deployments
   - Use CODEOWNERS file
   - Enable branch protection rules

## Maintenance

This repository is intended for demos and testing. We intentionally left out long-term maintenance tasks from the documentation to keep the workflows minimal and focused on PR validation and deployment from dev to main.

### Updating Workflows

When modifying workflows:

1. Test changes in a feature branch first
2. Use workflow dispatch to test manually
3. Review logs carefully
4. Update documentation

## Support and Troubleshooting

### Useful Commands

```bash
# Check cluster status
az connectedk8s show -n <cluster-name> -g <resource-group>

# Get cluster credentials locally
az connectedk8s proxy -n <cluster-name> -g <resource-group>

# View deployments
kubectl get deployments

# View pods and logs
kubectl get pods -l app=<app-name>
kubectl logs -l app=<app-name> --tail=50

# Describe resources
kubectl describe deployment <app-name>
kubectl describe pod <pod-name>

# Check events
kubectl get events --sort-by='.lastTimestamp'
```

### Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Azure Arc-enabled Kubernetes](https://docs.microsoft.com/en-us/azure/azure-arc/kubernetes/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Docker Documentation](https://docs.docker.com/)

## Contributing

When adding new applications:

1. Create directory under `iotopps/`
2. Add `Dockerfile`
3. Add `deployment.yaml`
4. Add `README.md`
5. Workflows will automatically detect and build/deploy

No workflow changes needed for new applications! 🎉
