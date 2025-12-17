#!/bin/bash

# Configure Fabric Endpoint for Azure IoT Operations Dataflows
# This script helps you set up the connection to Microsoft Fabric Real-Time Intelligence

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Fabric Endpoint Configuration${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo "You need the following from your Fabric Eventstream:"
echo "1. Bootstrap server (format: xxx.servicebus.windows.net:9093)"
echo "2. Connection string (starts with 'Endpoint=sb://...')"
echo ""
echo "To get these:"
echo "  - Go to https://app.fabric.microsoft.com"
echo "  - Open your Eventstream"
echo "  - Click on event hub connection (under 'Custom sources')"
echo "  - Copy the connection information"
echo ""

read -p "Enter bootstrap server: " BOOTSTRAP_SERVER
read -p "Enter connection string: " CONNECTION_STRING

if [ -z "$BOOTSTRAP_SERVER" ] || [ -z "$CONNECTION_STRING" ]; then
    echo -e "${RED}ERROR: Both bootstrap server and connection string are required${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Creating Kubernetes secret...${NC}"

# Create the secret
kubectl create secret generic fabric-realtime-secret \
    -n azure-iot-operations \
    --from-literal=username='$ConnectionString' \
    --from-literal=password="$CONNECTION_STRING" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓ Secret created${NC}"
echo ""

# Update the endpoint YAML
ENDPOINT_FILE="../operations/fabric-realtime-endpoint.yaml"

if [ -f "$ENDPOINT_FILE" ]; then
    echo -e "${YELLOW}Updating endpoint configuration...${NC}"
    
    # Create backup
    cp "$ENDPOINT_FILE" "${ENDPOINT_FILE}.bak"
    
    # Update the host
    sed -i "s|host: \"YOUR_FABRIC_EVENTHUB.servicebus.windows.net:9093\"|host: \"$BOOTSTRAP_SERVER\"|g" "$ENDPOINT_FILE"
    
    echo -e "${GREEN}✓ Endpoint configuration updated${NC}"
    echo ""
    
    echo -e "${YELLOW}Applying endpoint configuration...${NC}"
    kubectl apply -f "$ENDPOINT_FILE"
    
    echo -e "${GREEN}✓ Endpoint applied${NC}"
else
    echo -e "${RED}ERROR: Endpoint file not found: $ENDPOINT_FILE${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Configuration Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "The dataflows should now connect to Fabric."
echo ""
echo "Verify with:"
echo "  kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=50"
echo ""
echo "Check Fabric Eventstream for incoming data:"
echo "  https://app.fabric.microsoft.com"
echo ""
