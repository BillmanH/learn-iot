#!/bin/bash
# Find or create a valid namespace resource for IoT Operations deployment

# Load configuration
CONFIG_FILE="linux_aio_config.json"
CLUSTER_NAME=$(jq -r '.azure.cluster_name' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
SUBSCRIPTION_ID=$(jq -r '.azure.subscription_id' "$CONFIG_FILE")
LOCATION=$(jq -r '.azure.location' "$CONFIG_FILE")

echo "=== Checking for Existing Asset Endpoint Profiles ==="
az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.DeviceRegistry/assetEndpointProfiles" \
  --query "[].{name:name, id:id}" -o table

echo ""
echo "=== Getting IDs ==="
EXISTING_ENDPOINTS=$(az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.DeviceRegistry/assetEndpointProfiles" \
  --query "[].id" -o tsv)

if [ -n "$EXISTING_ENDPOINTS" ]; then
    FIRST_ENDPOINT=$(echo "$EXISTING_ENDPOINTS" | head -n 1)
    echo "Found existing asset endpoint profile:"
    echo "$FIRST_ENDPOINT"
    echo ""
    echo "You can use this as the namespace resource ID:"
    echo "export NAMESPACE_RESOURCE_ID=\"$FIRST_ENDPOINT\""
    echo ""
    echo "Or add to linux_aio_config.json:"
    echo '  "azure": {'
    echo "    \"namespace_resource_id\": \"$FIRST_ENDPOINT\""
    echo '  }'
else
    echo "No existing asset endpoint profiles found."
    echo ""
    echo "Creating a new one in Kubernetes first..."
    
    cat > /tmp/temp-namespace-endpoint.yaml << 'EOF'
apiVersion: deviceregistry.microsoft.com/v1
kind: AssetEndpointProfile
metadata:
  name: aio-namespace-placeholder
  namespace: azure-iot-operations
spec:
  uuid: aio-namespace-placeholder
  targetAddress: "opc.tcp://placeholder:50000"
  endpointProfileType: Microsoft.AssetEndpointProfile/opcua/1.0.0
  authentication:
    method: Anonymous
  additionalConfiguration: |
    {
      "applicationName": "Namespace Placeholder"
    }
EOF
    
    echo "Applying Kubernetes manifest..."
    kubectl apply -f /tmp/temp-namespace-endpoint.yaml
    
    echo ""
    echo "Waiting for resource to sync to Azure (30 seconds)..."
    sleep 30
    
    echo ""
    echo "Checking if it appeared in Azure..."
    NAMESPACE_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.DeviceRegistry/assetEndpointProfiles/aio-namespace-placeholder"
    
    if az resource show --ids "$NAMESPACE_RESOURCE_ID" &>/dev/null; then
        echo "✅ Resource synced to Azure successfully!"
        echo ""
        echo "Use this namespace resource ID:"
        echo "$NAMESPACE_RESOURCE_ID"
    else
        echo "⚠️  Resource not synced yet. This is expected if rsync isn't enabled."
        echo ""
        echo "You have a chicken-and-egg problem:"
        echo "  • Need namespace resource to create IoT Ops instance"
        echo "  • Need IoT Ops instance with rsync to sync namespace resource to Azure"
        echo ""
        echo "Solution: Use the existing 'spaceship-factory-opcua' endpoint as namespace:"
        FALLBACK_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.DeviceRegistry/assetEndpointProfiles/spaceship-factory-opcua"
        echo "$FALLBACK_ID"
        echo ""
        echo "Set this in the script before deployment:"
        echo "export NAMESPACE_RESOURCE_ID=\"$FALLBACK_ID\""
    fi
fi
