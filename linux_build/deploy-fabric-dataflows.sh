#!/bin/bash

# Deploy Fabric Dataflows for Factory MQTT Telemetry
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

# Create temporary file with updated topic IDs
TEMP_FILE=$(mktemp)
sed "s|es_YOUR_FABRIC_TOPIC_ID|$FABRIC_TOPIC_ID|g" "$SCRIPT_DIR/../operations/fabric-factory-dataflows.yaml" | \
    sed "s|es_YOUR_FABRIC_ALERTS_TOPIC|$FABRIC_ALERTS_TOPIC_ID|g" > "$TEMP_FILE"

# Deployment strategy selection
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Select Deployment Strategy${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "1) Aggregated - All factory data in one stream (recommended)"
echo "2) Per-Machine - Separate dataflows for each machine type"
echo "3) Critical-Only - Only critical alerts (temp > 80, errors, maintenance)"
echo "4) Aggregated + Critical - All data + separate alert stream"
echo "5) All Dataflows - Deploy everything (testing/development)"
echo ""
read -p "Select strategy (1-5): " STRATEGY

case $STRATEGY in
    1)
        DATAFLOWS="factory-aggregated"
        echo -e "${GREEN}✓ Selected: Aggregated (all data, single stream)${NC}"
        ;;
    2)
        DATAFLOWS="factory-cnc-to-fabric factory-3dprinter-to-fabric factory-welding-to-fabric"
        echo -e "${GREEN}✓ Selected: Per-Machine (separate streams)${NC}"
        ;;
    3)
        DATAFLOWS="factory-critical-only"
        echo -e "${GREEN}✓ Selected: Critical-Only (alerts only)${NC}"
        ;;
    4)
        DATAFLOWS="factory-aggregated factory-critical-only"
        echo -e "${GREEN}✓ Selected: Aggregated + Critical (dual stream)${NC}"
        ;;
    5)
        DATAFLOWS="all"
        echo -e "${GREEN}✓ Selected: All Dataflows (complete deployment)${NC}"
        ;;
    *)
        echo -e "${RED}Invalid selection. Exiting.${NC}"
        rm "$TEMP_FILE"
        exit 1
        ;;
esac
echo ""

# Deploy Fabric endpoint first
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Deploying Fabric Endpoint${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

if [ -f "$SCRIPT_DIR/../operations/fabric-realtime-endpoint.yaml" ]; then
    echo -e "${BLUE}Applying fabric-realtime-endpoint.yaml...${NC}"
    kubectl apply -f "$SCRIPT_DIR/../operations/fabric-realtime-endpoint.yaml"
    echo -e "${GREEN}✓ Fabric endpoint deployed${NC}"
else
    echo -e "${YELLOW}⚠ fabric-realtime-endpoint.yaml not found. Skipping...${NC}"
    echo "Note: You may need to create this file manually."
fi
echo ""

# Deploy dataflows
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Deploying Dataflows${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

if [ "$DATAFLOWS" == "all" ]; then
    echo -e "${BLUE}Deploying all dataflows...${NC}"
    kubectl apply -f "$TEMP_FILE"
    echo -e "${GREEN}✓ All dataflows deployed${NC}"
else
    # Deploy selected dataflows only
    for DATAFLOW_NAME in $DATAFLOWS; do
        echo -e "${BLUE}Deploying: ${DATAFLOW_NAME}...${NC}"
        
        # Extract specific dataflow from file (include from metadata: line to next --- or EOF)
        awk "/metadata:/,/^---$/ { 
            if (/name: ${DATAFLOW_NAME}$/) { 
                found=1; 
                # Go back to find apiVersion
                for (i=NR-10; i<NR; i++) {
                    if (i in lines && lines[i] ~ /^apiVersion:/) {
                        start=i;
                        break;
                    }
                }
            } 
            if (found && NR >= start) print 
            if (/^---$/ && found) exit 
        } 
        { lines[NR]=$0 }" "$TEMP_FILE" | kubectl apply -f -
        
        echo -e "${GREEN}✓ ${DATAFLOW_NAME} deployed${NC}"
    done
fi

echo ""

# Cleanup temp file
rm "$TEMP_FILE"

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
