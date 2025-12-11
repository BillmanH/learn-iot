#!/bin/bash
# Remove OPC UA assets and endpoint profile

echo "=== Removing OPC UA Asset Endpoint Profile ==="
kubectl delete assetendpointprofile spaceship-factory-opcua -n azure-iot-operations

echo ""
echo "=== Removing OPC UA Simulator ==="
kubectl delete deployment opc-plc-simulator -n azure-iot-operations
kubectl delete service opc-plc-service -n azure-iot-operations
kubectl delete configmap factory-opc-nodes -n azure-iot-operations

echo ""
echo "=== Verification ==="
echo "Remaining asset endpoint profiles:"
kubectl get assetendpointprofiles -n azure-iot-operations

echo ""
echo "Remaining assets:"
kubectl get assets -n azure-iot-operations

echo ""
echo "✅ OPC UA components removed"
echo "MQTT components (spaceship-factory-mqtt) remain intact"
