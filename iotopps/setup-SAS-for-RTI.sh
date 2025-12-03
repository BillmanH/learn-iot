#!/bin/bash
# Setup SAS Key Authentication for Fabric Real-Time Intelligence
# This script creates a Kubernetes secret for Azure IoT Operations to connect to Fabric Event Stream

set -e

echo "=========================================="
echo "Fabric RTI SAS Authentication Setup"
echo "=========================================="
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo "Error: Cannot connect to Kubernetes cluster"
    echo "Please ensure your kubeconfig is set up correctly"
    exit 1
fi

# Prompt for connection string
echo "From your Fabric Event Stream custom endpoint (Kafka protocol),"
echo "copy the 'Connection string-primary key' value."
echo ""
echo "Paste the connection string here:"
read -r CONNECTION_STRING

if [ -z "$CONNECTION_STRING" ]; then
    echo "Error: Connection string cannot be empty"
    exit 1
fi

# Validate connection string format
if [[ ! "$CONNECTION_STRING" =~ ^Endpoint= ]]; then
    echo "Warning: Connection string doesn't appear to be in the expected format"
    echo "Expected format: Endpoint=sb://..."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if secret already exists
SECRET_NAME="fabric-realtime-secret"
NAMESPACE="azure-iot-operations"

if kubectl get secret $SECRET_NAME -n $NAMESPACE &> /dev/null; then
    echo ""
    echo "⚠️  Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'"
    echo ""
    echo "This secret is ONLY used for Fabric Real-Time Intelligence connectivity."
    echo "Replacing it will NOT affect:"
    echo "  - Your MQTT broker authentication (uses 'aio-akv-sp')"
    echo "  - Sputnik or other MQTT publishers"
    echo "  - Any other secrets in your cluster"
    echo ""
    read -p "Do you want to delete and recreate it? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting existing secret..."
        kubectl delete secret $SECRET_NAME -n $NAMESPACE
    else
        echo "Aborting. Secret not modified."
        exit 0
    fi
fi

# Create the secret
echo ""
echo "Creating Kubernetes secret..."
kubectl create secret generic $SECRET_NAME \
  -n $NAMESPACE \
  --from-literal=username='$ConnectionString' \
  --from-literal=password="$CONNECTION_STRING"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Success! Secret '$SECRET_NAME' created in namespace '$NAMESPACE'"
    echo ""
    echo "Next steps:"
    echo "1. Update fabric-realtime-endpoint.yaml with your bootstrap server"
    echo "2. Update fabric-realtime-dataflow.yaml with your topic name"
    echo "3. Apply the configurations:"
    echo "   kubectl apply -f operations/fabric-realtime-endpoint.yaml"
    echo "   kubectl apply -f operations/fabric-realtime-dataflow.yaml"
    echo ""
    echo "To verify the secret was created:"
    echo "   kubectl get secret $SECRET_NAME -n $NAMESPACE"
else
    echo ""
    echo "❌ Failed to create secret"
    exit 1
fi
