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

ASSET_COUNT_AFTER=$(az iot ops asset query --instance "$INSTANCE_NAME" -g "$RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null || echo "0")

if [ "$ASSET_COUNT_AFTER" -eq "0" ]; then
    echo ""
    echo "⚠️  Assets still not syncing. Checking orchestrator logs..."
    echo ""
    echo "=== Orchestrator Pods ==="
    kubectl get pods -n azure-iot-operations | grep -E "aio-orc|orchestrator"
    
    echo ""
    echo "=== Recent Orchestrator Logs ==="
    kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator --tail=50 2>/dev/null || echo "Could not fetch orchestrator logs"
    
    echo ""
    echo "=== Asset Status in Kubernetes ==="
    kubectl get asset spaceship-assembly-line-1 -n azure-iot-operations -o jsonpath='{.status}' 2>/dev/null | jq '.' 2>/dev/null || echo "No status available"
    
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check if orchestrator pods are running:"
    echo "   kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator"
    echo "2. Check full orchestrator logs:"
    echo "   kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator"
    echo "3. Verify managed identity has permissions:"
    echo "   az role assignment list --scope /subscriptions/$(jq -r '.azure.subscription_id' $CONFIG_FILE)/resourceGroups/$RESOURCE_GROUP"
else
    echo ""
    echo "✅ Assets successfully synced to Azure!"
fi

echo ""
echo "If still empty, check:"
echo "• kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator"
echo "• RBAC permissions for the managed identity"
