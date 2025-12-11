#!/bin/bash
# Deploy MQTT assets using ARM templates

# Load configuration from linux_aio_config.json
CONFIG_FILE="linux_aio_config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi

RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
LOCATION=$(jq -r '.azure.location' "$CONFIG_FILE")
CLUSTER_NAME=$(jq -r '.azure.cluster_name' "$CONFIG_FILE")

# Get custom location ID from the Arc-enabled cluster
echo "=== Getting Custom Location from Arc Cluster ==="
CUSTOM_LOCATION=$(az connectedk8s show \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "id" -o tsv 2>/dev/null)

if [ -z "$CUSTOM_LOCATION" ]; then
    echo "Warning: Could not auto-detect custom location"
    echo "You may need to manually specify the custom location in the ARM templates"
fi

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  Cluster: $CLUSTER_NAME"
echo ""

echo "=== Deploying MQTT Asset Endpoint Profile via ARM ==="
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file arm_templates/mqtt-asset-endpoint.json \
  --parameters location="$LOCATION" \
  --name "mqtt-endpoint-deployment-$(date +%s)"

echo ""
echo "=== Deploying MQTT Asset via ARM ==="
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file arm_templates/mqtt-asset.json \
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
