#!/bin/bash
# Diagnose and fix missing orchestrator for resource sync

# Load configuration
CONFIG_FILE="linux_aio_config.json"
CLUSTER_NAME=$(jq -r '.azure.cluster_name' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
INSTANCE_NAME="${CLUSTER_NAME}-aio"

echo "=== Checking Azure IoT Operations Pods ==="
echo "All pods in azure-iot-operations namespace:"
kubectl get pods -n azure-iot-operations

echo ""
echo "=== Searching for Orchestrator/Sync Components ==="
echo "Note: In AIO v1.2+, resource sync is handled by aio-operator (no separate orchestrator)"
echo ""
echo "Checking aio-operator status:"
kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=aio-operator

echo ""
echo "=== Checking IoT Operations Instance ==="
echo "Querying Azure for IoT Operations instance details..."
INSTANCE_INFO=$(az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "{name:name,provisioningState:properties.provisioningState,version:properties.version}" -o table 2>/dev/null)
if [ -n "$INSTANCE_INFO" ]; then
    echo "$INSTANCE_INFO"
    PROVISIONING_STATE=$(az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.provisioningState" -o tsv 2>/dev/null)
else
    echo "Could not retrieve instance details"
    PROVISIONING_STATE="Unknown"
fi

echo ""
echo "=== Checking for Device Registry Sync Controller ==="
SYNC_PODS=$(kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=deviceregistry-sync 2>/dev/null)
if echo "$SYNC_PODS" | grep -q "Running"; then
    echo "$SYNC_PODS"
else
    echo "No device registry sync pods found (checking alternative components...)"
    # Check for ADR components which handle sync in newer versions
    kubectl get pods -n azure-iot-operations | grep -i "adr\|akri" || echo "No ADR/Akri components found"
fi

echo ""
echo "=== Resource Sync Status ==="
# Check if rsync is enabled in the IoT Ops instance
RSYNC_ENABLED=$(az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.components.resourceSync.enabled" -o tsv 2>/dev/null)

if [ "$RSYNC_ENABLED" = "true" ]; then
    echo "✓ Resource Sync is ENABLED"
    echo ""
    echo "Checking sync configuration:"
    az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.components.resourceSync" -o json 2>/dev/null | jq '.' 2>/dev/null || echo "Could not retrieve sync details"
    echo ""
    echo "Verifying assets can sync:"
    ASSETS_COUNT=$(kubectl get assets -A --no-headers 2>/dev/null | wc -l)
    echo "  - Assets in Kubernetes: $ASSETS_COUNT"
    echo "  - If assets exist but aren't syncing, check aio-operator logs"
elif [ "$RSYNC_ENABLED" = "false" ]; then
    echo "✗ Resource Sync is DISABLED"
    echo ""
    echo "To enable resource sync, run:"
    echo "  az iot ops enable-rsync --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
else
    echo "⚠ Resource Sync status unknown (property may not exist in this version)"
    echo ""
    echo "To enable/verify resource sync, run:"
    echo "  az iot ops enable-rsync --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
fi

echo ""
echo "=== Diagnosis Summary ==="
# Count running pods
RUNNING_PODS=$(kubectl get pods -n azure-iot-operations --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -n azure-iot-operations --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$PROVISIONING_STATE" = "Succeeded" ] && [ "$RUNNING_PODS" -gt 20 ]; then
    echo "✓ IoT Operations deployment appears healthy"
    echo "✓ Provisioning State: $PROVISIONING_STATE"
    echo "✓ Running Pods: $RUNNING_PODS/$TOTAL_PODS"
    echo ""
    echo "If assets are not syncing to Azure, check:"
    echo "1. Resource sync is enabled (see above)"
    echo "2. Assets are properly configured in Kubernetes"
    echo "3. Check logs: kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-operator"
elif [ "$PROVISIONING_STATE" = "Succeeded" ]; then
    echo "⚠ IoT Operations provisioned but fewer pods than expected"
    echo "  Provisioning State: $PROVISIONING_STATE"
    echo "  Running Pods: $RUNNING_PODS/$TOTAL_PODS"
    echo ""
    echo "  Check for pod issues:"
    echo "  kubectl get pods -n azure-iot-operations | grep -v Running"
else
    echo "✗ IoT Operations deployment may have issues"
    echo "  Provisioning State: $PROVISIONING_STATE"
    echo "  Running Pods: $RUNNING_PODS/$TOTAL_PODS"
    echo ""
    echo "  Troubleshooting steps:"
    echo "  1. Re-run initialization: az iot ops init --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
    echo "  2. Check for updates: az iot ops update --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
    echo "  3. Check operator logs: kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-operator"
fi
