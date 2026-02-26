// ============================================================================
// Azure IoT Operations — azd up path
// Root Bicep orchestration template
// ============================================================================
// Deploy with:  azd up  (from the azd-deploy/ directory)
// Parameters are sourced from azd env — see main.parameters.template.json
// ============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('azd environment name — used to derive all resource names. Set automatically by `azd init`.')
param environmentName string

@description('Name for the Arc-enabled Kubernetes cluster. Defaults to the azd environment name.')
param clusterName string = environmentName

// Globally unique names: derived from resourceGroup().id so they are stable across re-deployments
// but unique per subscription+RG. Prefixed with a short mnemonic and truncated to stay within limits.
// Must be variables (not parameter defaults) because resourceGroup() is not allowed in param defaults.
var kvSuffix   = take(uniqueString(resourceGroup().id), 8)
var storSuffix = take(uniqueString(resourceGroup().id, 'stor'), 8)
var acrSuffix  = take(uniqueString(resourceGroup().id, 'acr'), 8)

var defaultKeyVaultName        = 'kv-${take(environmentName, 13)}-${kvSuffix}'    // max 24
var defaultStorageAccountName  = 'st${take(replace(toLower(environmentName), '-', ''), 12)}${storSuffix}' // max 22
var defaultSchemaRegistryName  = '${take(environmentName, 20)}-schema-reg'
var defaultManagedIdentityName = '${take(environmentName, 30)}-aio-mi'
var defaultAcrName             = 'acr${take(replace(toLower(environmentName), '-', ''), 12)}${acrSuffix}' // max 23
var defaultNamespaceName       = '${take(environmentName, 40)}-dr-ns'

@description('Name for the Azure Key Vault (3-24 chars, globally unique). Leave blank to auto-generate.')
@maxLength(24)
param keyVaultName string = ''

@description('Name for the storage account (3-24 chars, lowercase alphanumeric). Leave blank to auto-generate.')
@maxLength(24)
param storageAccountName string = ''

@description('Name for the IoT Operations schema registry. Leave blank to auto-generate.')
param schemaRegistryName string = ''

@description('Name for the user-assigned managed identity. Leave blank to auto-generate.')
param managedIdentityName string = ''

@description('Name for the Azure Container Registry (5-50 chars, alphanumeric). Leave blank to auto-generate.')
@maxLength(50)
param containerRegistryName string = ''

@description('Name for the Device Registry namespace (required for AIO v1.2+ --ns-resource-id). Leave blank to auto-generate.')
param deviceRegistryNamespaceName string = ''

// Resolve: use explicit param if provided, otherwise fall back to generated default
var resolvedKeyVaultName        = empty(keyVaultName)        ? defaultKeyVaultName        : keyVaultName
var resolvedStorageAccountName  = empty(storageAccountName)  ? defaultStorageAccountName  : storageAccountName
var resolvedSchemaRegistryName  = empty(schemaRegistryName)  ? defaultSchemaRegistryName  : schemaRegistryName
var resolvedManagedIdentityName = empty(managedIdentityName) ? defaultManagedIdentityName : managedIdentityName
var resolvedAcrName             = empty(containerRegistryName)          ? defaultAcrName          : containerRegistryName
var resolvedNamespaceName       = empty(deviceRegistryNamespaceName) ? defaultNamespaceName    : deviceRegistryNamespaceName

@description('Admin username for the edge VM.')
param vmAdminUsername string = 'aiouser'

@description('SSH public key content for the edge VM. Set AZURE_VM_SSH_PUBLIC_KEY in azd env, or leave blank to let pre-provision.ps1 generate one.')
@secure()
param vmSshPublicKey string

@description('Azure VM size for the edge VM.')
param vmSize string = 'Standard_D4s_v3'

@description('Object ID of the deploying user — granted Key Vault Secrets Officer and IoT Ops Data roles. Set automatically by pre-provision.ps1.')
param deployerObjectId string = ''

@description('Keep NSG port 22 open after provisioning.')
param openSshPort bool = true

@description('Install k9s terminal Kubernetes UI on the VM.')
param installK9s bool = false

@description('Install mqttui terminal MQTT client on the VM.')
param installMqttui bool = false

@description('Resource tags applied to all resources.')
param tags object = {
  deployedBy: 'azd'
  purpose: 'iot-operations-learning'
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    clusterName: clusterName
    openSshPort: openSshPort
    tags: tags
  }
}

module keyVault 'modules/keyVault.bicep' = {
  name: 'keyVault'
  params: {
    location: location
    keyVaultName: resolvedKeyVaultName
    tags: tags
  }
}

module storageAccount 'modules/storageAccount.bicep' = {
  name: 'storageAccount'
  params: {
    location: location
    storageAccountName: resolvedStorageAccountName
    tags: tags
  }
}

module managedIdentity 'modules/managedIdentity.bicep' = {
  name: 'managedIdentity'
  params: {
    location: location
    managedIdentityName: resolvedManagedIdentityName
    tags: tags
  }
}

module containerRegistry 'modules/containerRegistry.bicep' = {
  name: 'containerRegistry'
  params: {
    location: location
    containerRegistryName: resolvedAcrName
    tags: tags
  }
}

module deviceRegistryNamespace 'modules/deviceRegistryNamespace.bicep' = {
  name: 'deviceRegistryNamespace'
  params: {
    namespaceName: resolvedNamespaceName
    location: location
    tags: tags
  }
}

module schemaRegistry 'modules/schemaRegistry.bicep' = {
  name: 'schemaRegistry'
  dependsOn: [ storageAccount ]
  params: {
    location: location
    schemaRegistryName: resolvedSchemaRegistryName
    storageAccountName: resolvedStorageAccountName
    tags: tags
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vm'
  params: {
    location: location
    clusterName: clusterName
    adminUsername: vmAdminUsername
    sshPublicKey: vmSshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.subnetId
    publicIpId: network.outputs.publicIpId
    nsgId: network.outputs.nsgId
    installK9s: installK9s
    installMqttui: installMqttui
    tags: tags
  }
}

module roleAssignments 'modules/roleAssignments.bicep' = {
  name: 'roleAssignments'
  params: {
    keyVaultName: resolvedKeyVaultName
    storageAccountName: resolvedStorageAccountName
    containerRegistryName: resolvedAcrName
    aioManagedIdentityPrincipalId: managedIdentity.outputs.principalId
    schemaRegistryPrincipalId: schemaRegistry.outputs.schemaRegistryPrincipalId
    vmSystemIdentityPrincipalId: vm.outputs.systemIdentityPrincipalId
    deployerObjectId: deployerObjectId
  }
}

// ---------------------------------------------------------------------------
// Outputs  (consumed by post-provision.ps1 via azd env)
// ---------------------------------------------------------------------------

output AZURE_VM_NAME string = vm.outputs.vmName
output AZURE_VM_PUBLIC_IP string = network.outputs.publicIpAddress
output AIO_CLUSTER_NAME string = clusterName
output AIO_KEY_VAULT_URI string = keyVault.outputs.keyVaultUri
output AIO_KEY_VAULT_NAME string = resolvedKeyVaultName
output AIO_SCHEMA_REGISTRY_NAME string = resolvedSchemaRegistryName
output AIO_MANAGED_IDENTITY_NAME string = resolvedManagedIdentityName
output AIO_MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
output AZURE_CONTAINER_REGISTRY_LOGIN_SERVER string = containerRegistry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resolvedAcrName
output AIO_DEVICE_REGISTRY_NAMESPACE_ID string = deviceRegistryNamespace.outputs.namespaceId
output AIO_DEVICE_REGISTRY_NAMESPACE_NAME string = resolvedNamespaceName
