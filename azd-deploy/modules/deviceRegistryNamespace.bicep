// ============================================================================
// deviceRegistryNamespace.bicep
// Creates a Device Registry namespace required for AIO v1.2+ asset management.
// The resource ID is passed to `az iot ops create --ns-resource-id`.
// ============================================================================

@description('Name of the Device Registry namespace.')
param namespaceName string

@description('Azure region for the namespace.')
param location string = resourceGroup().location

@description('Resource tags.')
param tags object = {}

resource drNamespace 'Microsoft.DeviceRegistry/namespaces@2025-10-01' = {
  name: namespaceName
  location: location
  tags: tags
  properties: {}
}

output namespaceId string = drNamespace.id
output namespaceName string = drNamespace.name
