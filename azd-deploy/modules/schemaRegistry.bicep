// ============================================================================
// Schema Registry module — IoT Operations schema registry
// Ported from arm_templates/schemaRegistry.json
// ============================================================================

param location string
param schemaRegistryName string
param storageAccountName string
param containerName string = 'schemas'
param tags object = {}

var storageSuffix = environment().suffixes.storage
var blobEndpoint = 'https://${storageAccountName}.blob.${storageSuffix}/${containerName}'

resource schemaRegistry 'Microsoft.DeviceRegistry/schemaRegistries@2025-10-01' = {
  name: schemaRegistryName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    namespace: take(schemaRegistryName, 32)
    storageAccountContainerUrl: blobEndpoint
  }
}

output schemaRegistryId string = schemaRegistry.id
output schemaRegistryName string = schemaRegistry.name
output schemaRegistryPrincipalId string = schemaRegistry.identity.principalId
