// ============================================================================
// Role Assignments module — all RBAC in one place
//
// Assignments created:
//   Key Vault Secrets User       → AIO managed identity (for secret sync)
//   Key Vault Secrets Officer    → deploying user       (to seed secrets)
//   Storage Blob Data Contributor→ schema registry      (to read/write schemas)
//   AcrPull                      → VM system identity   (to pull module images)
// ============================================================================

param keyVaultName string
param storageAccountName string
param containerRegistryName string

@description('Principal ID of the AIO user-assigned managed identity.')
param aioManagedIdentityPrincipalId string

@description('System-assigned principal ID of the schema registry (for Storage Blob Data Contributor).')
param schemaRegistryPrincipalId string

@description('System-assigned principal ID of the edge VM (for AcrPull).')
param vmSystemIdentityPrincipalId string

@description('Object ID of the deploying user (for Key Vault Secrets Officer).')
param deployerObjectId string

// ---------------------------------------------------------------------------
// Well-known role definition GUIDs
// ---------------------------------------------------------------------------
var kvSecretsUserRoleId    = '4633458b-17de-408a-b874-0445c86b69e6'  // Key Vault Secrets User
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'  // Key Vault Secrets Officer
var storBlobContribRoleId  = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'  // Storage Blob Data Contributor
var acrPullRoleId          = '7f951dda-4ed3-4680-a7ca-43fe172d538d'  // AcrPull

// ---------------------------------------------------------------------------
// Existing resource references (for scoped role assignments)
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

// ---------------------------------------------------------------------------
// 1. Key Vault Secrets User → AIO managed identity
//    Allows AIO to read secrets from Key Vault during secret sync
// ---------------------------------------------------------------------------
resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, aioManagedIdentityPrincipalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: aioManagedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// 2. Key Vault Secrets Officer → deploying user
//    Allows the deployer to seed placeholder secrets (e.g. Fabric connection string)
// ---------------------------------------------------------------------------
resource kvSecretsOfficerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerObjectId, kvSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: deployerObjectId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// 3. Storage Blob Data Contributor → schema registry system identity
//    Allows schema registry to read/write schemas in the storage container
// ---------------------------------------------------------------------------
resource storBlobContribAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, schemaRegistryPrincipalId, storBlobContribRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storBlobContribRoleId)
    principalId: schemaRegistryPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// 4. AcrPull → VM system-assigned identity
//    Allows K3s on the VM to pull module images from ACR without credentials
// ---------------------------------------------------------------------------
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, vmSystemIdentityPrincipalId, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: vmSystemIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}
