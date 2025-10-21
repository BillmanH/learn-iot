# GitHub Actions Secrets and Variables Setup

This document describes all the secrets and variables you need to configure in your GitHub repository for the IoT Edge deployment workflows.

## Required Secrets

Navigate to your repository → **Settings** → **Secrets and variables** → **Actions** to add these secrets. The workflows only reference the secrets listed below — I trimmed anything unused.

List of secrets referenced by the workflows (alphabetical):

- `ACR_PASSWORD` — Azure Container Registry admin password (only required if you authenticate to ACR with username/password). Used by the ACR login step.
- `ACR_USERNAME` — Azure Container Registry admin username (only required if you authenticate to ACR with username/password). Used by the ACR login step.
- `AZURE_CREDENTIALS` — Preferred: service principal JSON used by `azure/login` (recommended). See creation snippet below.
- `AZURE_SUBSCRIPTION_ID` — Subscription ID used for `az account set` when `AZURE_CREDENTIALS` is not used.
- `DOCKER_PASSWORD` — Docker Hub password or access token (required if using Docker Hub credentials).
- `DOCKER_USERNAME` — Docker Hub username (used for login and as the fallback namespace when `REGISTRY_NAME` is empty).

Only add the registry secrets for the provider you use (ACR vs Docker Hub). The registry namespace/name itself should be configured as the repository variable `REGISTRY_NAME` (see Variables section below).

### Azure Authentication (create `AZURE_CREDENTIALS`)

Create an Azure service principal with appropriate rights and store the JSON in `AZURE_CREDENTIALS`. Example (CLI):

```bash
az ad sp create-for-rbac --name "github-actions-iot-edge" \
  --role contributor \
  --scopes /subscriptions/{subscription-id}/resourceGroups/{resource-group-name} \
  --sdk-auth
```

Save the entire JSON output as the `AZURE_CREDENTIALS` secret. The workflow also supports using `AZURE_SUBSCRIPTION_ID` when `AZURE_CREDENTIALS` is not provided, but `AZURE_CREDENTIALS` is the recommended approach.

Example output (truncated):

```json
{
  "clientId": "<GUID>",
  "clientSecret": "<GUID>",
  "subscriptionId": "<GUID>",
  "tenantId": "<GUID>"
}
```

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
- [ ] `ACR_PASSWORD` (if using ACR) added
- [ ] `ACR_USERNAME` (if using ACR) added
- [ ] `AZURE_CREDENTIALS` secret added with valid JSON
- [ ] `AZURE_SUBSCRIPTION_ID` secret added (if not using `AZURE_CREDENTIALS`)
- [ ] `DOCKER_PASSWORD` (if using Docker Hub) added
- [ ] `DOCKER_USERNAME` (if using Docker Hub) added
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
