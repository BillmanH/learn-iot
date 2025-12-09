#!/bin/bash
# Fix missing managed identity for IoT Operations instance

# Load configuration
CONFIG_FILE="linux_aio_config.json"
CLUSTER_NAME=$(jq -r '.azure.cluster_name' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
INSTANCE_NAME="${CLUSTER_NAME}-aio"

echo "=== Current Instance Configuration ==="
az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "{name:name,identity:identity.type,provisioningState:properties.provisioningState}" -o table

echo ""
echo "=== Problem: Missing Managed Identity ==="
echo "Your IoT Operations instance has identity.type = 'None'"
echo "This prevents the orchestrator from syncing assets to Azure."
echo ""
echo "=== Solution: Enable Resource Sync ==="
echo "The 'az iot ops enable-rsync' command should configure the identity..."
echo ""

# Enable rsync with explicit configuration
echo "Running: az iot ops enable-rsync --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
if az iot ops enable-rsync --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP"; then
    echo "✅ Rsync enabled"
else
    echo "⚠️  Failed with default settings, trying with K8 Bridge SP OID..."
    K8_BRIDGE_SP_OID=$(az ad sp list --display-name "K8 Bridge" --query "[0].id" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$K8_BRIDGE_SP_OID" ]; then
        echo "Found K8 Bridge SP: $K8_BRIDGE_SP_OID"
        az iot ops enable-rsync --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --k8-bridge-sp-oid "$K8_BRIDGE_SP_OID"
    fi
fi

echo ""
echo "=== Checking Updated Configuration ==="
sleep 5
az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "{name:name,identity:identity.type,provisioningState:properties.provisioningState}" -o table

echo ""
IDENTITY_TYPE=$(az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "identity.type" -o tsv)

if [ "$IDENTITY_TYPE" = "None" ]; then
    echo "❌ Identity still not configured"
    echo ""
    echo "The issue may be that your IoT Operations instance was created without --enable-rsync"
    echo "You may need to recreate the instance with the flag enabled, or manually configure:"
    echo ""
    echo "Option 1: Update the instance (may not be supported)"
    echo "  az resource update --ids <instance-resource-id> --set identity.type=SystemAssigned"
    echo ""
    echo "Option 2: Redeploy with rsync enabled"
    echo "  Add --enable-rsync to the 'az iot ops create' command in linuxAIO.sh"
    echo "  Then re-run the deployment"
else
    echo "✅ Identity configured: $IDENTITY_TYPE"
    echo ""
    echo "Wait 2-3 minutes for orchestrator to deploy, then check:"
    echo "  kubectl get pods -n azure-iot-operations | grep orc"
    echo "  az iot ops asset query --instance $INSTANCE_NAME -g $RESOURCE_GROUP"
fi
