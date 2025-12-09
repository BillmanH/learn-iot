#!/bin/bash
# Check and enable resource sync for Azure IoT Operations

# Load configuration from JSON file
CONFIG_FILE="linux_aio_config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi

CLUSTER_NAME=$(jq -r '.azure.cluster_name' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
INSTANCE_NAME="${CLUSTER_NAME}-aio"

echo "Configuration loaded from $CONFIG_FILE:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Instance: $INSTANCE_NAME"
echo ""

echo "=== Checking Current Rsync Status ==="
echo "Querying assets in Azure..."
ASSET_COUNT=$(az iot ops asset query --instance "$INSTANCE_NAME" -g "$RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null || echo "0")
echo "Assets found in Azure: $ASSET_COUNT"

echo ""
echo "Assets in Kubernetes:"
kubectl get assets -n azure-iot-operations --no-headers | wc -l

echo ""
echo "=== Enabling Resource Sync ==="
echo "Running: az iot ops enable-rsync --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"

if az iot ops enable-rsync --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP"; then
    echo "✅ Resource sync enabled successfully"
else
    echo "⚠️  Failed to enable resource sync"
    echo ""
    echo "Trying with K8 Bridge service principal OID..."
    K8_BRIDGE_SP_OID=$(az ad sp list --display-name "K8 Bridge" --query "[0].id" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$K8_BRIDGE_SP_OID" ]; then
        echo "Found K8 Bridge SP OID: $K8_BRIDGE_SP_OID"
        if az iot ops enable-rsync --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --k8-bridge-sp-oid "$K8_BRIDGE_SP_OID"; then
            echo "✅ Resource sync enabled with explicit OID"
        else
            echo "❌ Failed to enable resource sync even with explicit OID"
            echo "Check permissions and RBAC configuration"
        fi
    else
        echo "Could not find K8 Bridge service principal"
    fi
fi

echo ""
echo "=== Waiting for Sync ==="
echo "Waiting 30 seconds for initial sync..."
sleep 30

echo ""
echo "=== Verifying Assets in Azure ==="
az iot ops asset query --instance "$INSTANCE_NAME" -g "$RESOURCE_GROUP"

echo ""
echo "If still empty, check:"
echo "• kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator"
echo "• RBAC permissions for the managed identity"
