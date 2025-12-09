#!/bin/bash
# Deploy MQTT-based assets for spaceship factory

set -e

echo "=== Deploying MQTT Asset Endpoint Profile ==="
kubectl apply -f mqtt-asset-endpoint.yaml

echo ""
echo "=== Deploying Example Asset ==="
kubectl apply -f mqtt-asset-example.yaml

echo ""
echo "=== Verifying Deployment ==="
kubectl get assetendpointprofiles -n azure-iot-operations
kubectl get assets -n azure-iot-operations

echo ""
echo "=== Enable Resource Sync (if not already enabled) ==="
echo "Run: az iot ops enable-rsync --name <instance-name> --resource-group <resource-group>"

echo ""
echo "=== Next Steps ==="
echo "1. Wait 2-3 minutes for resources to sync to Azure"
echo "2. Go to Azure Portal → Your IoT Operations Instance → Assets"
echo "3. You should see 'spaceship-assembly-line-1' in the Assets list"
echo "4. Create additional assets by modifying mqtt-asset-example.yaml"
echo ""
echo "Note: MQTT assets are NOT auto-discovered. You must create them manually"
echo "or via manifests like the examples provided."
