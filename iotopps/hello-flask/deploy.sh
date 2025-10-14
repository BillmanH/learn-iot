#!/bin/bash
# deploy.sh - Build and deploy Flask app to IoT Edge K3s cluster

set -e

# Configuration - Update these values
REGISTRY_TYPE="dockerhub"  # Options: dockerhub, acr
REGISTRY_NAME="your-registry-name"  # Docker Hub username or ACR name
IMAGE_NAME="hello-flask"
IMAGE_TAG="latest"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Flask IoT Edge Deployment Script ===${NC}\n"

# Validate configuration
if [ "$REGISTRY_NAME" == "your-registry-name" ]; then
    echo -e "${RED}ERROR: Please update REGISTRY_NAME in this script${NC}"
    echo "Edit deploy.sh and set your Docker Hub username or ACR name"
    exit 1
fi

# Build full image name based on registry type
if [ "$REGISTRY_TYPE" == "acr" ]; then
    FULL_IMAGE_NAME="${REGISTRY_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
else
    FULL_IMAGE_NAME="${REGISTRY_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
fi

echo -e "${YELLOW}Step 1: Building Docker image...${NC}"
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
echo -e "${GREEN}✓ Build complete${NC}\n"

echo -e "${YELLOW}Step 2: Tagging image...${NC}"
docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${FULL_IMAGE_NAME}
echo -e "${GREEN}✓ Tagged as ${FULL_IMAGE_NAME}${NC}\n"

echo -e "${YELLOW}Step 3: Logging into registry...${NC}"
if [ "$REGISTRY_TYPE" == "acr" ]; then
    az acr login --name ${REGISTRY_NAME}
else
    docker login
fi
echo -e "${GREEN}✓ Logged in${NC}\n"

echo -e "${YELLOW}Step 4: Pushing image to registry...${NC}"
docker push ${FULL_IMAGE_NAME}
echo -e "${GREEN}✓ Image pushed${NC}\n"

echo -e "${YELLOW}Step 5: Updating deployment configuration...${NC}"
# Create a temporary deployment file with the correct image
sed "s|<YOUR_REGISTRY>|${REGISTRY_NAME}|g" deployment.yaml > deployment.tmp.yaml
echo -e "${GREEN}✓ Configuration updated${NC}\n"

echo -e "${YELLOW}Step 6: Deploying to Kubernetes...${NC}"
kubectl apply -f deployment.tmp.yaml
rm deployment.tmp.yaml
echo -e "${GREEN}✓ Deployment applied${NC}\n"

echo -e "${YELLOW}Step 7: Waiting for deployment to complete...${NC}"
kubectl rollout status deployment/hello-flask
echo -e "${GREEN}✓ Deployment ready${NC}\n"

# Get the node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "\nYour application is now accessible at:"
echo -e "${GREEN}http://${NODE_IP}:30080${NC}"
echo -e "\nTo test:"
echo -e "  curl http://${NODE_IP}:30080"
echo -e "  curl http://${NODE_IP}:30080/health"
echo -e "\nTo view logs:"
echo -e "  kubectl logs -l app=hello-flask"
echo -e "\nTo view pods:"
echo -e "  kubectl get pods -l app=hello-flask"
