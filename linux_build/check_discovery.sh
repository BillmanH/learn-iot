#!/bin/bash
# Script to check Azure IoT Operations asset discovery status

echo "=== Checking Asset Endpoint Profiles ==="
kubectl get assetendpointprofiles -n azure-iot-operations -o yaml

echo ""
echo "=== Checking OPC UA Simulator Status ==="
kubectl get pods -n azure-iot-operations -l app=opc-plc-simulator
kubectl logs -n azure-iot-operations -l app=opc-plc-simulator --tail=50

echo ""
echo "=== Checking OPC UA Service ==="
kubectl get svc opc-plc-service -n azure-iot-operations

echo ""
echo "=== Checking Azure IoT Operations Instance ==="
# Get the AIO instance name from your deployment
AIO_INSTANCE=$(kubectl get pods -n azure-iot-operations -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || echo "unknown")
echo "AIO Instance: $AIO_INSTANCE"

echo ""
echo "=== Checking for Discovery-related Pods ==="
kubectl get pods -n azure-iot-operations | grep -i "discover\|akri"

echo ""
echo "=== Instructions ==="
echo "1. Verify the AssetEndpointProfile has discovery enabled"
echo "2. Check that OPC UA simulator is running and accessible"
echo "3. Confirm rsync is enabled: az iot ops check --name <instance-name> --resource-group <resource-group>"
echo "4. Asset discovery can take several minutes to populate in the portal"
