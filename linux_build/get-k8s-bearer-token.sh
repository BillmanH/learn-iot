#!/bin/bash

# ============================================================================
# Kubernetes Service Account Bearer Token Retrieval Tool
# ============================================================================
# This script creates/retrieves a Kubernetes service account bearer token
# for viewing cluster resources in Azure Portal or other management tools.
#
# The script will:
#   1. Create a service account (if not exists)
#   2. Create a ClusterRoleBinding with cluster-admin permissions
#   3. Retrieve the bearer token
#   4. Copy token to clipboard (if available)
#   5. Save token to file for backup
#
# Usage:
#   ./get-k8s-bearer-token.sh [service-account-name]
#
# Arguments:
#   service-account-name: Optional. Name for the service account
#                        Default: azure-portal-viewer
#
# Output:
#   - Token displayed on screen
#   - Token copied to clipboard (if xclip/xsel available)
#   - Token saved to: <USB_DRIVE>/linux_aio/k8s_bearer_token.txt
#
# Author: Azure IoT Operations Team
# Date: January 2026
# Version: 1.0.0
# ============================================================================

set -e  # Exit on error

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SA_NAME="${1:-azure-portal-viewer}"
SA_NAMESPACE="default"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Kubernetes Bearer Token Retrieval Tool"
echo "=========================================="
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}ERROR: kubectl is not installed or not in PATH!${NC}"
    echo ""
    echo "Please install kubectl first:"
    echo "  sudo apt-get install -y kubectl"
    echo "  or download from: https://kubernetes.io/docs/tasks/tools/"
    echo ""
    exit 1
fi

# Check if we can connect to the cluster
echo "Checking Kubernetes cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster!${NC}"
    echo ""
    echo "Please ensure:"
    echo "  - K3s is running: systemctl status k3s"
    echo "  - KUBECONFIG is set: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    echo "  - You have proper permissions: sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Connected to Kubernetes cluster${NC}"
echo ""

# Display cluster info
CLUSTER_VERSION=$(kubectl version --short 2>/dev/null | grep "Server Version" | cut -d':' -f2 | xargs || echo "unknown")
CLUSTER_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
echo "Cluster Version: $CLUSTER_VERSION"
echo "Cluster Nodes: $CLUSTER_NODES"
echo ""

echo "=========================================="
echo "Creating Service Account"
echo "=========================================="
echo ""

# Check if service account already exists
if kubectl get serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}Service account '$SA_NAME' already exists in namespace '$SA_NAMESPACE'${NC}"
    echo "Would you like to use the existing service account? (y/n)"
    read -p "> " use_existing
    
    if [ "$use_existing" != "y" ] && [ "$use_existing" != "Y" ]; then
        echo "Please specify a different service account name:"
        read -p "> " new_name
        if [ -z "$new_name" ]; then
            echo -e "${RED}ERROR: Invalid service account name${NC}"
            exit 1
        fi
        SA_NAME="$new_name"
    fi
else
    echo "Creating service account: $SA_NAME"
    kubectl create serviceaccount "$SA_NAME" -n "$SA_NAMESPACE"
    echo -e "${GREEN}✓ Service account created${NC}"
fi

echo ""

# Create ClusterRoleBinding for cluster-admin access
BINDING_NAME="${SA_NAME}-binding"

echo "=========================================="
echo "Creating ClusterRoleBinding"
echo "=========================================="
echo ""

if kubectl get clusterrolebinding "$BINDING_NAME" &> /dev/null; then
    echo -e "${YELLOW}ClusterRoleBinding '$BINDING_NAME' already exists${NC}"
else
    echo "Creating ClusterRoleBinding: $BINDING_NAME"
    kubectl create clusterrolebinding "$BINDING_NAME" \
        --clusterrole=cluster-admin \
        --serviceaccount="${SA_NAMESPACE}:${SA_NAME}"
    echo -e "${GREEN}✓ ClusterRoleBinding created with cluster-admin permissions${NC}"
fi

echo ""
echo -e "${YELLOW}NOTE: This service account has cluster-admin permissions. Keep the token secure!${NC}"
echo ""

# Create a secret for the service account (if not automatically created)
echo "=========================================="
echo "Creating Service Account Token Secret"
echo "=========================================="
echo ""

SECRET_NAME="${SA_NAME}-token"

# Check if secret already exists
if kubectl get secret "$SECRET_NAME" -n "$SA_NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}Secret '$SECRET_NAME' already exists${NC}"
else
    echo "Creating secret: $SECRET_NAME"
    
    # Create secret manifest
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $SA_NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $SA_NAME
type: kubernetes.io/service-account-token
EOF
    
    echo -e "${GREEN}✓ Secret created${NC}"
    
    # Wait for token to be populated
    echo "Waiting for token to be populated..."
    sleep 2
fi

echo ""

# Retrieve the token
echo "=========================================="
echo "Retrieving Bearer Token"
echo "=========================================="
echo ""

# Try to get token from secret
TOKEN=""
MAX_RETRIES=5
RETRY_COUNT=0

while [ -z "$TOKEN" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$SA_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode)
    
    if [ -z "$TOKEN" ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "Token not ready yet, waiting... (attempt $RETRY_COUNT/$MAX_RETRIES)"
        sleep 2
    fi
done

if [ -z "$TOKEN" ]; then
    echo -e "${RED}ERROR: Failed to retrieve token from secret${NC}"
    echo ""
    echo "Debugging information:"
    kubectl get secret "$SECRET_NAME" -n "$SA_NAMESPACE" -o yaml
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Token retrieved successfully${NC}"
echo ""

# Display token
echo "=========================================="
echo "Service Account Bearer Token"
echo "=========================================="
echo ""
echo -e "${CYAN}Service Account:${NC} $SA_NAME"
echo -e "${CYAN}Namespace:${NC} $SA_NAMESPACE"
echo -e "${CYAN}Token Length:${NC} ${#TOKEN} characters"
echo ""
echo -e "${YELLOW}Bearer Token:${NC}"
echo "----------------------------------------"
echo "$TOKEN"
echo "----------------------------------------"
echo ""

# Try to copy to clipboard
if command -v xclip &> /dev/null; then
    echo "$TOKEN" | xclip -selection clipboard
    echo -e "${GREEN}✓ Token copied to clipboard (using xclip)${NC}"
    echo ""
elif command -v xsel &> /dev/null; then
    echo "$TOKEN" | xsel --clipboard
    echo -e "${GREEN}✓ Token copied to clipboard (using xsel)${NC}"
    echo ""
else
    echo -e "${YELLOW}NOTE: Clipboard tools (xclip/xsel) not available. Token not copied to clipboard.${NC}"
    echo "You can install xclip with: sudo apt-get install -y xclip"
    echo ""
fi

# Save token to file
echo "=========================================="
echo "Saving Token to File"
echo "=========================================="
echo ""

# Detect USB/SD drives (same logic as backup script)
DRIVES=()
DRIVE_LABELS=()

echo "Detecting USB/SD drives..."

# Method 1: Using lsblk (most reliable on Linux)
if command -v lsblk &> /dev/null; then
    while IFS= read -r line; do
        # Parse lsblk output: NAME, SIZE, TYPE, MOUNTPOINT, LABEL
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        mountpoint=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | awk '{print $4}')
        
        if [ -n "$mountpoint" ] && [ "$mountpoint" != "MOUNTPOINT" ]; then
            DRIVES+=("$mountpoint")
            if [ -n "$label" ]; then
                DRIVE_LABELS+=("$label ($size) - $mountpoint")
            else
                DRIVE_LABELS+=("$name ($size) - $mountpoint")
            fi
        fi
    done < <(
        for disk in $(lsblk -dpno NAME | grep -E "sd[b-z]|mmcblk"); do
            lsblk -no NAME,SIZE,MOUNTPOINT,LABEL "$disk" | grep -E "part|disk" | grep -v "^$(basename "$disk") "
        done
    )
fi

# Method 2: Fallback - check common mount points
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo "Using fallback method to detect drives..."
    for mount_point in /media/$USER/* /mnt/*; do
        if [ -d "$mount_point" ] && mountpoint -q "$mount_point" 2>/dev/null; then
            size=$(df -h "$mount_point" | tail -1 | awk '{print $2}')
            DRIVES+=("$mount_point")
            DRIVE_LABELS+=("$(basename "$mount_point") ($size) - $mount_point")
        fi
    done
fi

# If no drives found, offer to save locally
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No USB/SD drives detected.${NC}"
    echo ""
    echo "Would you like to save the token locally? (y/n)"
    read -p "> " save_local
    
    if [ "$save_local" = "y" ] || [ "$save_local" = "Y" ]; then
        LOCAL_DIR="$HOME/k8s-tokens"
        mkdir -p "$LOCAL_DIR"
        TOKEN_FILE="$LOCAL_DIR/k8s_bearer_token_$(date +%Y%m%d_%H%M%S).txt"
        
        # Save token and metadata
        cat > "$TOKEN_FILE" <<EOF
# Kubernetes Service Account Bearer Token
# Generated: $(date)
# Service Account: $SA_NAME
# Namespace: $SA_NAMESPACE
# Cluster Version: $CLUSTER_VERSION

$TOKEN
EOF
        
        chmod 600 "$TOKEN_FILE"
        echo -e "${GREEN}✓ Token saved to: $TOKEN_FILE${NC}"
        echo ""
    else
        echo "Token not saved to file. Please copy it from above."
        echo ""
    fi
else
    # Display available drives
    echo ""
    echo "Available drives:"
    for i in "${!DRIVES[@]}"; do
        echo "  [$((i+1))] ${DRIVE_LABELS[$i]}"
    done
    echo ""
    
    # Select drive
    echo "Select a drive to save the token (1-${#DRIVES[@]}):"
    read -p "> " drive_choice
    
    # Validate choice
    if ! [[ "$drive_choice" =~ ^[0-9]+$ ]] || [ "$drive_choice" -lt 1 ] || [ "$drive_choice" -gt ${#DRIVES[@]} ]; then
        echo -e "${RED}ERROR: Invalid drive selection${NC}"
        echo "Token not saved to file. Please copy it from above."
        exit 1
    fi
    
    # Get selected drive
    SELECTED_DRIVE="${DRIVES[$((drive_choice-1))]}"
    BACKUP_DIR="$SELECTED_DRIVE/linux_aio"
    
    echo ""
    echo "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    TOKEN_FILE="$BACKUP_DIR/k8s_bearer_token_$(date +%Y%m%d_%H%M%S).txt"
    
    # Save token and metadata
    cat > "$TOKEN_FILE" <<EOF
# Kubernetes Service Account Bearer Token
# Generated: $(date)
# Service Account: $SA_NAME
# Namespace: $SA_NAMESPACE
# Cluster Version: $CLUSTER_VERSION
# Cluster Nodes: $CLUSTER_NODES

# How to use this token:
# 1. Go to Azure Portal
# 2. Navigate to your Arc-enabled Kubernetes cluster
# 3. Click on "Kubernetes resources" in the left menu
# 4. Paste this token when prompted
# 5. Click "Sign in"

# Bearer Token:
$TOKEN
EOF
    
    chmod 600 "$TOKEN_FILE"
    echo -e "${GREEN}✓ Token saved to: $TOKEN_FILE${NC}"
    echo ""
fi

# Display usage instructions
echo "=========================================="
echo "Usage Instructions"
echo "=========================================="
echo ""
echo "To use this token in Azure Portal:"
echo "  1. Navigate to your Arc-enabled Kubernetes cluster"
echo "  2. Click 'Kubernetes resources' (or 'Workloads')"
echo "  3. When prompted for a bearer token, paste the token above"
echo "  4. Click 'Sign in'"
echo ""
echo "To verify the token works:"
echo "  kubectl --token=\"\$TOKEN\" get pods --all-namespaces"
echo ""
echo -e "${YELLOW}Security Note:${NC}"
echo "  - This token has cluster-admin permissions"
echo "  - Keep it secure and don't share it publicly"
echo "  - Consider using RBAC to create limited-permission tokens"
echo "  - Token file permissions are set to 600 (owner read/write only)"
echo ""

# Display service account details
echo "=========================================="
echo "Service Account Details"
echo "=========================================="
echo ""
kubectl get serviceaccount "$SA_NAME" -n "$SA_NAMESPACE"
echo ""
kubectl get clusterrolebinding "$BINDING_NAME"
echo ""

echo -e "${GREEN}✓ Bearer token retrieval complete!${NC}"
echo ""

# Optional: Display cleanup instructions
echo "To delete the service account and revoke access:"
echo "  kubectl delete serviceaccount $SA_NAME -n $SA_NAMESPACE"
echo "  kubectl delete clusterrolebinding $BINDING_NAME"
echo "  kubectl delete secret $SECRET_NAME -n $SA_NAMESPACE"
echo ""
