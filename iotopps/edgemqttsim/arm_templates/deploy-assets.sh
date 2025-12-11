#!/bin/bash
# Deploy MQTT assets using ARM templates

# Load configuration
CONFIG_FILE="../../../linux_build/linux_aio_config.json"
RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
LOCATION=$(jq -r '.azure.location' "$CONFIG_FILE")

echo "=== Deploying MQTT Asset Endpoint Profile via ARM ==="
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file mqtt-asset-endpoint.json \
  --parameters location="$LOCATION" \
  --name "mqtt-endpoint-deployment-$(date +%s)"

echo ""
echo "=== Deploying MQTT Asset via ARM ==="
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file mqtt-asset.json \
  --parameters location="$LOCATION" \
  --name "mqtt-asset-deployment-$(date +%s)"

echo ""
echo "=== Verifying Deployment ==="
echo "Asset Endpoint Profiles:"
az resource list --resource-group "$RESOURCE_GROUP" --resource-type Microsoft.DeviceRegistry/assetEndpointProfiles --query "[].{Name:name, Location:location}" -o table

echo ""
echo "Assets:"
az resource list --resource-group "$RESOURCE_GROUP" --resource-type Microsoft.DeviceRegistry/assets --query "[].{Name:name, Location:location}" -o table

echo ""
echo "✓ Deployment complete!"
echo "View in portal: https://portal.azure.com/#view/Microsoft_Azure_DeviceRegistry/AssetsListBlade"
