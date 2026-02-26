// ============================================================================
// Key Vault module — RBAC-authorized, soft-delete enabled
// Ported from arm_templates/keyVault.json
// ============================================================================

param location string
param keyVaultName string
@allowed([ 'standard', 'premium' ])
param skuName string = 'standard'
param enableSoftDelete bool = true
param softDeleteRetentionInDays int = 90
param tags object = {}

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: skuName
    }
    // RBAC authorization — role assignments handle access, not access policies
    enableRbacAuthorization: true
    enableSoftDelete: enableSoftDelete
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
