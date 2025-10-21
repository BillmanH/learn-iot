# GitHub Actions Secrets and Variables Setup

This document describes all the secrets and variables you need to configure in your GitHub repository for the IoT Edge deployment workflows.

## Required Secrets

Navigate to your repository → **Settings** → **Secrets and variables** → **Actions** to add these secrets.

### Azure Authentication Secrets

#### `AZURE_CREDENTIALS`
Service Principal credentials for Azure authentication. Create using:

```bash
az ad sp create-for-rbac --name "github-actions-iot-edge" \
  --role contributor \
  --scopes /subscriptions/{subscription-id}/resourceGroups/{resource-group-name} \
  --sdk-auth
```

The output JSON should be stored as-is in this secret. Format:
```json
{
  "clientId": "<GUID>",
  "clientSecret": "<GUID>",
  "subscriptionId": "<GUID>",
  "tenantId": "<GUID>",
  "activeDirectoryEndpointUrl": "https://login.microsoftonline.com",
  "resourceManagerEndpointUrl": "https://management.azure.com/",
  "activeDirectoryGraphResourceId": "https://graph.windows.net/",
  "sqlManagementEndpointUrl": "https://management.core.windows.net:8443/",
  "galleryEndpointUrl": "https://gallery.azure.com/",
  "managementEndpointUrl": "https://management.core.windows.net/"
}
```

#### `AZURE_SUBSCRIPTION_ID`
Your Azure subscription ID (GUID format)

Example: `12345678-1234-1234-1234-123456789012`

### Container Registry Secrets

Choose **ONE** of the following registry types:

#### For Docker Hub:
- **`DOCKER_USERNAME`**: Your Docker Hub username
- **`DOCKER_PASSWORD`**: Your Docker Hub password or access token

#### For Azure Container Registry (ACR):
- **`ACR_NAME`**: Name of your ACR (e.g., `myiotregistry`)
- **`ACR_USERNAME`**: ACR admin username (found in ACR → Access keys)
- **`ACR_PASSWORD`**: ACR admin password (found in ACR → Access keys)

**Note:** If using ACR with the Azure service principal, you may not need separate ACR credentials if the service principal has `acrpull` and `acrpush` roles.

### SSH Secrets (Optional - for direct edge device access)

These are optional and only needed if you want to deploy directly to edge devices without using Arc:

- **`EDGE_DEVICE_SSH_KEY`**: Private SSH key for accessing edge devices
- **`EDGE_DEVICE_USER`**: SSH username (default: `azureuser`)

## Repository Variables

Navigate to your repository → **Settings** → **Secrets and variables** → **Actions** → **Variables** tab to add these.

### Required Variables

#### `AZURE_RESOURCE_GROUP`
Name of your Azure resource group where IoT Operations cluster is deployed

Example: `rg-iot-operations`

#### `AZURE_CLUSTER_NAME`
Name of your Arc-enabled Kubernetes cluster

Example: `iot-ops-cluster`

#### `AZURE_LOCATION`
Azure region where resources are deployed

Example: `eastus`

#### `REGISTRY_TYPE`
Type of container registry: `dockerhub` or `acr`

#### `REGISTRY_NAME`
- For Docker Hub: Your Docker Hub username
- For ACR: Your ACR name (without `.azurecr.io`)

### Optional Variables

#### `IMAGE_TAG_PREFIX`
Prefix for image tags (default: `v`)

Example: `v` will create tags like `v1.0.0`

#### `EDGE_DEVICE_IP`
IP address of edge device (if deploying directly without Arc)

Example: `192.168.1.100`

## Environments (Recommended)

For better organization, create GitHub Environments for different deployment stages:

1. Navigate to **Settings** → **Environments**
2. Create environments: `development`, `staging`, `production`
3. Configure environment-specific secrets/variables
4. Add protection rules (required reviewers, wait timer, etc.)

### Example Environment Setup

**Development Environment:**
- `AZURE_RESOURCE_GROUP`: `rg-iot-dev`
- `AZURE_CLUSTER_NAME`: `iot-ops-dev-cluster`
- All other secrets/variables

**Production Environment:**
- `AZURE_RESOURCE_GROUP`: `rg-iot-prod`
- `AZURE_CLUSTER_NAME`: `iot-ops-prod-cluster`
- Add protection rules (2 required reviewers)
- All other secrets/variables

## Verification Checklist

Before running workflows, verify:

- [ ] Azure service principal created with appropriate permissions
- [ ] `AZURE_CREDENTIALS` secret added with valid JSON
- [ ] `AZURE_SUBSCRIPTION_ID` secret added
- [ ] Container registry credentials added (Docker Hub OR ACR)
- [ ] `AZURE_RESOURCE_GROUP` variable set
- [ ] `AZURE_CLUSTER_NAME` variable set
- [ ] `AZURE_LOCATION` variable set
- [ ] `REGISTRY_TYPE` variable set to `dockerhub` or `acr`
- [ ] `REGISTRY_NAME` variable set correctly

## Testing Your Configuration

You can test your secrets by running the workflow manually:

1. Go to **Actions** tab in your repository
2. Select the workflow (e.g., "Deploy IoT Edge Application")
3. Click "Run workflow"
4. Select the application and branch
5. Click "Run workflow"

Check the workflow logs to verify authentication and deployment steps.

## Security Best Practices

1. **Use Service Principals**: Never use personal Azure credentials
2. **Rotate Secrets Regularly**: Update secrets every 90 days
3. **Least Privilege**: Grant minimal permissions needed
4. **Environment Protection**: Use required reviewers for production
5. **Audit Logs**: Regularly review Actions workflow runs
6. **Secret Scanning**: Enable GitHub secret scanning for the repository

## Troubleshooting

### Azure Authentication Fails
- Verify service principal has not expired
- Check subscription ID is correct
- Ensure service principal has Contributor role on resource group

### Docker Push Fails
- Verify registry credentials are correct
- Check registry name format (no `.azurecr.io` suffix for ACR in variables)
- Ensure service principal has `acrpush` role if using ACR

### Kubectl Connection Fails
- Verify cluster name is correct
- Check Arc agent is running: `az connectedk8s show -n <cluster-name> -g <resource-group>`
- Ensure service principal has Kubernetes permissions on Arc cluster

### Deployment Times Out
- Check cluster connectivity
- Verify image can be pulled from registry
- Review pod logs: `kubectl logs -l app=<app-name>`

## Additional Resources

- [GitHub Actions Secrets Documentation](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [Azure Service Principal Creation](https://docs.microsoft.com/en-us/cli/azure/create-an-azure-service-principal-azure-cli)
- [Arc-enabled Kubernetes Access](https://docs.microsoft.com/en-us/azure/azure-arc/kubernetes/cluster-connect)
- [Azure Container Registry Authentication](https://docs.microsoft.com/en-us/azure/container-registry/container-registry-authentication)
