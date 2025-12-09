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

if [ "$IDENTITY_TYPE" = "None" ] || [ -z "$IDENTITY_TYPE" ]; then
    echo "❌ Identity still not configured"
    echo ""
    echo "⚠️  CRITICAL: The instance needs to be deleted and recreated with --enable-rsync"
    echo ""
    echo "Steps to fix:"
    echo "1. Delete the current instance:"
    echo "   az iot ops delete --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
    echo ""
    echo "2. Re-run the installation script:"
    echo "   bash linuxAIO.sh"
    echo ""
    echo "The updated linuxAIO.sh now includes --enable-rsync and will:"
    echo "  • Create a system-assigned managed identity"
    echo "  • Deploy the orchestrator operator pods"
    echo "  • Enable automatic asset syncing to Azure"
    echo ""
    echo "Note: Your existing K3s cluster and Azure resources will remain intact."
    echo "Only the IoT Operations instance will be recreated."
else
    echo "✅ Identity configured: $IDENTITY_TYPE"
    echo ""
    echo "Checking if orchestrator pods are deploying..."
    sleep 10
    
    ORCH_PODS=$(kubectl get pods -n azure-iot-operations 2>/dev/null | grep -c "orc\|deviceregistry" || echo "0")
    
    if [ "$ORCH_PODS" -gt "0" ]; then
        echo "✅ Orchestrator pods found: $ORCH_PODS"
        kubectl get pods -n azure-iot-operations | grep -E "orc|deviceregistry"
    else
        echo "⚠️  No orchestrator pods found yet"
        echo "Wait a few minutes for pods to deploy, then check:"
        echo "  kubectl get pods -n azure-iot-operations | grep orc"
    fi
    
    echo ""
    echo "After orchestrator pods are running, verify assets sync:"
    echo "  az iot ops asset query --instance $INSTANCE_NAME -g $RESOURCE_GROUP"
fi
