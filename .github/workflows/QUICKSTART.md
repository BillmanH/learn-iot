 # Quick Start Guide: GitHub Actions for IoT Edge

Get your IoT Edge deployments automated in 15 minutes! ⚡

## Step 1: Create Azure Service Principal (5 minutes)

Open Azure Cloud Shell or your terminal and run:

```bash
# Replace with your values
SUBSCRIPTION_ID="your-subscription-id"
RESOURCE_GROUP="rg-iot-operations"

# Create service principal
az ad sp create-for-rbac \
  --name "github-actions-iot-edge" \
  --role contributor \
  --scopes /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP \
  --sdk-auth
```

📋 **Copy the entire JSON output** - you'll need it in the next step!

## Step 2: Configure GitHub Secrets (5 minutes)

1. Go to your repository on GitHub
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret** for each:

### Required Secrets:

| Secret Name | Value | Where to Find |
|-------------|-------|---------------|
| `AZURE_CREDENTIALS` | JSON from Step 1 | Paste entire JSON output |
| `AZURE_SUBSCRIPTION_ID` | Your subscription ID | Azure Portal or `az account show` |
| `DOCKER_USERNAME` | Your Docker Hub username | hub.docker.com |
| `DOCKER_PASSWORD` | Your Docker Hub password | hub.docker.com (or create token) |

**For Azure Container Registry instead of Docker Hub:**
| Secret Name | Value |
|-------------|-------|
| `ACR_NAME` | Your ACR name (without .azurecr.io) |
| `ACR_USERNAME` | ACR username from Access Keys |
| `ACR_PASSWORD` | ACR password from Access Keys |

## Step 3: Configure GitHub Variables (3 minutes)

1. Same page, click **Variables** tab
2. Click **New repository variable** for each:

| Variable Name | Example Value | Description |
|---------------|---------------|-------------|
| `AZURE_RESOURCE_GROUP` | `rg-iot-operations` | Your resource group name |
| `AZURE_CLUSTER_NAME` | `iot-ops-cluster` | Your Arc cluster name |
| `AZURE_LOCATION` | `eastus` | Azure region |
| `REGISTRY_TYPE` | `dockerhub` or `acr` | Which registry you're using |
| `REGISTRY_NAME` | `myusername` or `myacr` | Registry name |

## Step 4: Test Your Setup (2 minutes)

1. Go to **Actions** tab in GitHub
2. Select **"Build and Test IoT Applications"** workflow
3. Click **"Run workflow"** and choose an app (e.g., `hello-flask`)

✅ If this completes successfully, the build pipeline is working.

## Step 5: Deploy Your First App (1 minute)

1. Go to **Actions** tab
2. Select **"Deploy IoT Edge Application"** workflow
3. Click **"Run workflow"**
4. Choose:
   - Application: `hello-flask`
   - Environment: `development`
5. Click **"Run workflow"**

🚀 Watch it deploy!

## What Happens Automatically Now?

### On Pull Requests:
- ✅ Builds Docker images
- ✅ Validates Kubernetes manifests
- ✅ Comments on PR with status

### On Merge to Main/Dev:
- ✅ Builds and pushes images
- ✅ Deploys changed apps to cluster
- ✅ Verifies deployment success

### Monitoring:
- ✅ Reports on deployments (manual checks only)

## Common First-Time Issues

### Issue: "Azure login failed"
**Solution:** Check `AZURE_CREDENTIALS` secret is the complete JSON (starts with `{` and ends with `}`)

### Issue: "Docker push failed"
**Solution:** 
- Docker Hub: Verify username/password
- ACR: Verify you used the name without `.azurecr.io`

### Issue: "Cannot connect to cluster"
**Solution:** 
- Run: `az connectedk8s show -n <cluster-name> -g <resource-group>`
- Ensure cluster shows `"connectivityStatus": "Connected"`

### Issue: "Permission denied"
**Solution:** Grant service principal these roles:
```bash
# For Arc cluster access
az role assignment create \
  --role "Azure Arc Kubernetes Cluster User Role" \
  --assignee <service-principal-id> \
  --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Kubernetes/connectedClusters/<cluster-name>

# For ACR push (if using ACR)
az role assignment create \
  --role "AcrPush" \
  --assignee <service-principal-id> \
  --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr-name>
```

## Next Steps

1. 📖 Read [README.md](./README.md) for full workflow details
2. 🔐 Review [GITHUB_SECRETS_SETUP.md](./GITHUB_SECRETS_SETUP.md) for security best practices
3. 🏗️ Add your own applications under `iotopps/` directory
4. 🌍 Set up production environment with approvals

## Need Help?

Check the workflow run logs:
1. Go to **Actions** tab
2. Click on the failed workflow run
3. Click on the failed job
4. Review the logs for error messages

Most issues are authentication-related and can be fixed by double-checking your secrets and variables!

---

**🎉 Congratulations!** You now have a fully automated CI/CD pipeline for your IoT Edge applications!
