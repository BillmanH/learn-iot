// ============================================================================
// Managed Identity module — user-assigned identity for AIO secret sync
// Ported from arm_templates/managedIdentity.json
// ============================================================================

param location string
param managedIdentityName string
param tags object = {}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: tags
}

output managedIdentityId string = managedIdentity.id
output managedIdentityName string = managedIdentity.name
output principalId string = managedIdentity.properties.principalId
output clientId string = managedIdentity.properties.clientId
