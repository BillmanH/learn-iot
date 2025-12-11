#!/bin/bash

# Deploy Fabric Dataflows for Factory MQTT Telemetry using ARM Templates
# This script deploys dataflow configurations to route MQTT messages to Microsoft Fabric RTI

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/linux_aio_config.json"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Factory Fabric Dataflow Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}ERROR: Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq not found. Please install jq to parse JSON.${NC}"
    echo "Install: sudo apt-get install jq"
    exit 1
fi

echo -e "${YELLOW}Loading configuration from: $CONFIG_FILE${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}ERROR: kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

# Check if connected to cluster
echo -e "${YELLOW}Checking cluster connection...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}ERROR: Not connected to Kubernetes cluster.${NC}"
    echo "Please configure kubectl to connect to your cluster."
    exit 1
fi

CLUSTER_NAME=$(kubectl config current-context)
echo -e "${GREEN}✓ Connected to cluster: ${CLUSTER_NAME}${NC}"
echo ""

# Check if azure-iot-operations namespace exists
echo -e "${YELLOW}Checking azure-iot-operations namespace...${NC}"
if ! kubectl get namespace azure-iot-operations &> /dev/null; then
    echo -e "${RED}ERROR: azure-iot-operations namespace not found.${NC}"
    echo "Please ensure Azure IoT Operations is installed."
    exit 1
fi
echo -e "${GREEN}✓ Namespace exists${NC}"
echo ""

# Read Azure configuration from config file
SUBSCRIPTION_ID=$(jq -r '.azure.subscription_id' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$CONFIG_FILE")
CLUSTER_NAME=$(jq -r '.azure.cluster_name' "$CONFIG_FILE")

echo "Azure Configuration:"
echo "  Subscription: $SUBSCRIPTION_ID"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster: $CLUSTER_NAME"
echo ""

# Get custom location name
echo -e "${YELLOW}Getting custom location...${NC}"
CUSTOM_LOCATION=$(az iot ops show --cluster "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query "extendedLocation.name" -o tsv 2>/dev/null | awk -F'/' '{print $NF}')

if [ -z "$CUSTOM_LOCATION" ]; then
    echo -e "${RED}ERROR: Could not find custom location for cluster ${CLUSTER_NAME}${NC}"
    echo "Make sure Azure IoT Operations is installed."
    exit 1
fi

echo -e "${GREEN}✓ Custom Location: ${CUSTOM_LOCATION}${NC}"
echo ""

# Read Fabric configuration from config file
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Fabric Eventstream Configuration${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

FABRIC_TOPIC_ID=$(jq -r '.fabric.eventstream_topic_id // "es_YOUR_FABRIC_TOPIC_ID"' "$CONFIG_FILE")
FABRIC_ALERTS_TOPIC_ID=$(jq -r '.fabric.eventstream_alerts_topic_id // "es_YOUR_FABRIC_ALERTS_TOPIC"' "$CONFIG_FILE")

echo "Eventstream Topic ID: $FABRIC_TOPIC_ID"
echo "Alerts Topic ID: $FABRIC_ALERTS_TOPIC_ID"
echo ""

# Validate topic IDs
if [ "$FABRIC_TOPIC_ID" == "es_YOUR_FABRIC_TOPIC_ID" ]; then
    echo -e "${YELLOW}⚠ WARNING: Using placeholder topic ID from config file.${NC}"
    echo ""
    echo "To configure Fabric Eventstream:"
    echo "  1. Go to https://app.fabric.microsoft.com"
    echo "  2. Create or open your Eventstream"
    echo "  3. Copy the topic ID (format: es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb)"
    echo "  4. Update linux_build/linux_aio_config.json:"
    echo "     \"eventstream_topic_id\": \"es_YOUR_ACTUAL_TOPIC_ID\""
    echo ""
    read -p "Continue with placeholder? (y/N): " CONTINUE_PLACEHOLDER
    if [[ ! "$CONTINUE_PLACEHOLDER" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Deployment cancelled. Please update config file first.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Topic IDs loaded from config${NC}"
fi
echo ""

# Create fabric endpoint first if needed
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Deploying Fabric Endpoint${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Check if endpoint already exists in Kubernetes
if kubectl get dataflowendpoint fabric-realtime -n azure-iot-operations &> /dev/null; then
    echo -e "${GREEN}✓ Fabric endpoint already exists${NC}"
else
    if [ -f "$SCRIPT_DIR/../operations/fabric-realtime-endpoint.yaml" ]; then
        echo -e "${BLUE}Applying fabric-realtime-endpoint.yaml...${NC}"
        kubectl apply -f "$SCRIPT_DIR/../operations/fabric-realtime-endpoint.yaml"
        echo -e "${GREEN}✓ Fabric endpoint deployed${NC}"
    else
        echo -e "${YELLOW}⚠ fabric-realtime-endpoint.yaml not found. Skipping...${NC}"
    fi
fi
echo ""

# Deployment strategy selection
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Select Deployment Strategy${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "1) Aggregated - All factory data in one stream (recommended)"
echo "2) Per-Machine - Separate dataflows for CNC, 3D Printer, Welding"
echo ""
read -p "Select strategy (1-2): " STRATEGY

case $STRATEGY in
    1)
        ARM_TEMPLATES="fabric-dataflow-aggregated.json"
        echo -e "${GREEN}✓ Selected: Aggregated (all data, single stream)${NC}"
        ;;
    2)
        ARM_TEMPLATES="fabric-dataflow-cnc.json fabric-dataflow-3dprinter.json fabric-dataflow-welding.json"
        echo -e "${GREEN}✓ Selected: Per-Machine (separate streams)${NC}"
        ;;
    *)
        echo -e "${RED}Invalid selection. Exiting.${NC}"
        exit 1
        ;;
esac
echo ""

# Deploy dataflows using ARM templates
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Deploying Dataflows via ARM${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

for TEMPLATE in $ARM_TEMPLATES; do
    TEMPLATE_PATH="$SCRIPT_DIR/../operations/arm_templates/$TEMPLATE"
    DEPLOYMENT_NAME="dataflow-$(basename $TEMPLATE .json)-$(date +%s)"
    
    echo -e "${BLUE}Deploying: $TEMPLATE${NC}"
    
    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --name "$DEPLOYMENT_NAME" \
        --template-file "$TEMPLATE_PATH" \
        --parameters \
            customLocationName="$CUSTOM_LOCATION" \
            fabricTopicId="$FABRIC_TOPIC_ID" \
        --output table
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $(basename $TEMPLATE .json) deployed${NC}"
    else
        echo -e "${RED}✗ Failed to deploy $(basename $TEMPLATE .json)${NC}"
    fi
    echo ""
done

# Wait for dataflows to be ready
echo -e "${YELLOW}Waiting for dataflows to initialize...${NC}"
sleep 5

# Verify deployment
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Verification${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

echo -e "${BLUE}Deployed Dataflows:${NC}"
kubectl get dataflow -n azure-iot-operations -o wide

echo ""
echo -e "${BLUE}Dataflow Pods Status:${NC}"
kubectl get pods -n azure-iot-operations -l app=aio-dataflow

echo ""
echo -e "${BLUE}Recent Dataflow Logs:${NC}"
kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=20 --max-log-requests=10 2>/dev/null || \
    echo -e "${YELLOW}⚠ Could not retrieve logs (pods may still be starting)${NC}"

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next Steps:"
echo "1. Verify dataflows are running:"
echo "   kubectl get dataflow -n azure-iot-operations"
echo ""
echo "2. Check for errors:"
echo "   kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=50"
echo ""
echo "3. Monitor MQTT traffic reaching Fabric:"
echo "   - Go to https://app.fabric.microsoft.com"
echo "   - Open your Eventstream"
echo "   - Check 'Data preview' for incoming messages"
echo ""
echo "4. Verify message rate matches edge telemetry (~2.16 msg/sec)"
echo ""

if [ "$FABRIC_TOPIC_ID" == "es_YOUR_FABRIC_TOPIC_ID" ]; then
    echo -e "${YELLOW}⚠ IMPORTANT: You used placeholder topic IDs.${NC}"
    echo "   Update linux_build/linux_aio_config.json with actual topic IDs:"
    echo "   1. Get topic ID from Fabric portal: https://app.fabric.microsoft.com"
    echo "   2. Edit: linux_build/linux_aio_config.json"
    echo "   3. Update: \"eventstream_topic_id\": \"es_YOUR_ACTUAL_TOPIC_ID\""
    echo "   4. Re-run: bash linux_build/deploy-fabric-dataflows.sh"
    echo ""
fi

echo "Configuration file: $CONFIG_FILE"
echo "Dataflow definitions: operations/fabric-factory-dataflows.yaml"
echo ""
