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
echo "=== Searching for Orchestrator Components ==="
kubectl get all -n azure-iot-operations | grep -i "orc\|orchestrator" || echo "No orchestrator components found"

echo ""
echo "=== Checking IoT Operations Instance ==="
echo "Querying Azure for IoT Operations instance details..."
az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --query "{name:name,provisioningState:properties.provisioningState,version:properties.version}" -o table 2>/dev/null || echo "Could not retrieve instance details"

echo ""
echo "=== Checking for Device Registry Sync Controller ==="
kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=deviceregistry-sync || echo "No device registry sync pods found"

echo ""
echo "=== Problem Diagnosis ==="
echo "The orchestrator operator (aio-orc-operator) is missing from your cluster."
echo "This component is required for syncing assets from Kubernetes to Azure."
echo ""
echo "Possible causes:"
echo "1. The IoT Operations deployment didn't include the orchestrator"
echo "2. The orchestrator pods failed to start"
echo "3. The installation was incomplete"
echo ""
echo "Solution: Re-run the IoT Operations deployment to ensure all components are installed:"
echo "  az iot ops init --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
echo ""
echo "Or check if there's an update available:"
echo "  az iot ops update --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
