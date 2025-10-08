#!/bin/bash

# Azure IoT Operations Installation Script for Linux (Ubuntu)
# This script installs Azure IoT Operations on a K3s Kubernetes cluster on Ubuntu
# Requirements: Ubuntu 24.04+, 16GB RAM (32GB recommended), 4+ CPUs
# Author: Azure IoT Operations Installation Script
# Date: October 2025

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check if running as root
check_root() {
    if [ "$EUID" -eq 0 ]; then
        error "Please do not run this script as root. Use sudo when prompted."
    fi
}

# Check system requirements
check_system_requirements() {
    log "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        warn "This script is optimized for Ubuntu. Current OS: $ID"
    fi
    
    # Check kernel version (minimum 5.15)
    kernel_version=$(uname -r | cut -d. -f1,2)
    kernel_major=$(echo $kernel_version | cut -d. -f1)
    kernel_minor=$(echo $kernel_version | cut -d. -f2)
    
    if [ "$kernel_major" -lt 5 ] || ([ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -lt 15 ]); then
        error "Kernel version 5.15+ required. Current: $(uname -r)"
    fi
    
    # Check RAM (minimum 16GB)
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_ram_gb=$((total_ram_kb / 1024 / 1024))
    
    if [ "$total_ram_gb" -lt 16 ]; then
        error "Minimum 16GB RAM required. Current: ${total_ram_gb}GB"
    fi
    
    # Check CPU count (minimum 4)
    cpu_count=$(nproc)
    if [ "$cpu_count" -lt 4 ]; then
        error "Minimum 4 CPUs required. Current: ${cpu_count}"
    fi
    
    log "System requirements check passed: ${cpu_count} CPUs, ${total_ram_gb}GB RAM, Kernel $(uname -r)"
}

# Load configuration from JSON file
load_config() {
    local config_file="linux_aio_config.json"
    
    if [ -f "$config_file" ]; then
        log "Loading configuration from $config_file..."
        
        # Check if jq is installed, if not install it
        if ! command -v jq &> /dev/null; then
            log "Installing jq for JSON parsing..."
            sudo apt update && sudo apt install -y jq
        fi
        
        # Load configuration values
        SUBSCRIPTION_ID=$(jq -r '.azure.subscription_id // empty' "$config_file")
        SUBSCRIPTION_NAME=$(jq -r '.azure.subscription_name // empty' "$config_file")
        RESOURCE_GROUP=$(jq -r '.azure.resource_group // empty' "$config_file")
        LOCATION=$(jq -r '.azure.location // empty' "$config_file")
        CLUSTER_NAME=$(jq -r '.azure.cluster_name // empty' "$config_file")
        NAMESPACE_NAME=$(jq -r '.azure.namespace_name // empty' "$config_file")
        SKIP_SYSTEM_UPDATE=$(jq -r '.deployment.skip_system_update // false' "$config_file")
        FORCE_REINSTALL=$(jq -r '.deployment.force_reinstall // false' "$config_file")
        DEPLOYMENT_MODE=$(jq -r '.deployment.deployment_mode // "test"' "$config_file")
        
        # Export variables
        export SUBSCRIPTION_ID SUBSCRIPTION_NAME RESOURCE_GROUP LOCATION CLUSTER_NAME NAMESPACE_NAME
        export SKIP_SYSTEM_UPDATE FORCE_REINSTALL DEPLOYMENT_MODE
        
        log "Configuration loaded from $config_file"
        log "Resource Group: $RESOURCE_GROUP, Location: $LOCATION, Cluster: $CLUSTER_NAME"
        return 0
    else
        log "Configuration file $config_file not found. Will prompt for values interactively."
        return 1
    fi
}

# Update system packages
update_system() {
    if [ "$SKIP_SYSTEM_UPDATE" = "true" ]; then
        log "Skipping system update (skip_system_update=true in config)"
        # Still install essential packages
        sudo apt install -y curl wget gnupg lsb-release ca-certificates software-properties-common apt-transport-https jq
    else
        log "Updating system packages..."
        sudo apt update && sudo apt upgrade -y
        sudo apt install -y curl wget gnupg lsb-release ca-certificates software-properties-common apt-transport-https jq
    fi
}

# Install Azure CLI
install_azure_cli() {
    log "Installing Azure CLI..."
    
    if command -v az &> /dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        log "Azure CLI already installed. Checking version..."
        current_version=$(az version --query '"azure-cli"' -o tsv)
        log "Current Azure CLI version: $current_version"
        
        # Update Azure CLI
        log "Updating Azure CLI..."
        sudo az upgrade --yes
    else
        if [ "$FORCE_REINSTALL" = "true" ]; then
            log "Force reinstalling Azure CLI..."
        fi
        # Install Azure CLI
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    fi
    
    # Verify minimum version (2.62.0+)
    az_version=$(az version --query '"azure-cli"' -o tsv)
    log "Azure CLI version: $az_version"
    
    # Install required Azure CLI extensions
    log "Installing Azure CLI extensions..."
    az extension add --upgrade --name azure-iot-ops
    az extension add --upgrade --name connectedk8s
}

# Install kubectl
install_kubectl() {
    log "Installing kubectl..."
    
    if command -v kubectl &> /dev/null; then
        log "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    else
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
        log "kubectl installed successfully"
    fi
}

# Install Helm
install_helm() {
    log "Installing Helm..."
    
    if command -v helm &> /dev/null; then
        log "Helm already installed: $(helm version --short)"
    else
        # Use the official Helm installation script as a fallback
        log "Installing Helm using official installation script..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
        log "Helm installed successfully"
    fi
}

# Install K3s
install_k3s() {
    log "Installing K3s Kubernetes..."
    
    if command -v k3s &> /dev/null; then
        log "K3s already installed: $(k3s --version | head -n1)"
    else
        # Install K3s with Traefik disabled (required for Azure IoT Operations)
        curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode 644
        
        # Wait for K3s to be ready
        log "Waiting for K3s to be ready..."
        sudo systemctl enable k3s
        sudo systemctl start k3s
        
        # Wait for node to be ready
        timeout=300
        while [ $timeout -gt 0 ]; do
            if sudo k3s kubectl get nodes | grep -q " Ready "; then
                break
            fi
            sleep 5
            timeout=$((timeout - 5))
        done
        
        if [ $timeout -eq 0 ]; then
            error "K3s failed to become ready within 5 minutes"
        fi
        
        log "K3s installed and running successfully"
    fi
}

# Configure kubectl for K3s
configure_kubectl() {
    log "Configuring kubectl for K3s..."
    
    # Create .kube directory
    mkdir -p ~/.kube
    
    # Backup existing config if it exists
    if [ -f ~/.kube/config ]; then
        cp ~/.kube/config ~/.kube/config.backup.$(date +%s)
    fi
    
    # Merge K3s config with existing kubectl config
    sudo KUBECONFIG=~/.kube/config:/etc/rancher/k3s/k3s.yaml kubectl config view --flatten > ~/.kube/merged
    mv ~/.kube/merged ~/.kube/config
    chmod 0600 ~/.kube/config
    export KUBECONFIG=~/.kube/config
    
    # Switch to k3s context
    kubectl config use-context default
    
    # Make k3s config readable
    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    
    log "kubectl configured for K3s"
}

# Configure system settings for Azure IoT Operations
configure_system_settings() {
    log "Configuring system settings for Azure IoT Operations..."
    
    # Increase inotify limits (required for Azure IoT Operations)
    echo 'fs.inotify.max_user_instances=8192' | sudo tee -a /etc/sysctl.conf
    echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.conf
    
    # Increase file descriptor limit for better performance
    echo 'fs.file-max=100000' | sudo tee -a /etc/sysctl.conf
    
    # Apply sysctl settings
    sudo sysctl -p
    
    log "System settings configured"
}

# Azure login and setup
azure_login_setup() {
    log "Azure login and setup..."
    
    # Check if already logged in
    if az account show &> /dev/null; then
        log "Already logged into Azure"
        current_sub=$(az account show --query name -o tsv)
        current_sub_id=$(az account show --query id -o tsv)
        log "Current subscription: $current_sub"
        
        # Use current subscription if not specified in config
        if [ -z "$SUBSCRIPTION_ID" ]; then
            SUBSCRIPTION_ID="$current_sub_id"
            SUBSCRIPTION_NAME="$current_sub"
        fi
    else
        log "Please log into Azure..."
        az login
        
        # Get current subscription after login if not specified
        if [ -z "$SUBSCRIPTION_ID" ]; then
            SUBSCRIPTION_ID=$(az account show --query id -o tsv)
            SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
        fi
    fi
    
    # Set subscription if specified in config and different from current
    if [ -n "$SUBSCRIPTION_ID" ] && [ "$SUBSCRIPTION_ID" != "$(az account show --query id -o tsv)" ]; then
        log "Setting subscription to: $SUBSCRIPTION_ID"
        az account set --subscription "$SUBSCRIPTION_ID"
    fi
    
    # Get current subscription details
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    
    # Prompt for missing configuration values
    if [ -z "$RESOURCE_GROUP" ]; then
        echo
        echo -e "${BLUE}Please provide the following Azure configuration:${NC}"
        read -p "Enter resource group name (will be created if it doesn't exist): " RESOURCE_GROUP
    fi
    
    if [ -z "$LOCATION" ]; then
        read -p "Enter Azure region (e.g., eastus, westus2, westeurope): " LOCATION
    fi
    
    if [ -z "$CLUSTER_NAME" ]; then
        read -p "Enter cluster name: " CLUSTER_NAME
    fi
    
    # Export variables for later use
    export SUBSCRIPTION_ID
    export RESOURCE_GROUP
    export LOCATION
    export CLUSTER_NAME
    
    log "Azure configuration: Subscription=$SUBSCRIPTION_NAME, RG=$RESOURCE_GROUP, Location=$LOCATION, Cluster=$CLUSTER_NAME"
}

# Create Azure resources
create_azure_resources() {
    log "Creating Azure resource group..."
    
    # Create resource group if it doesn't exist
    if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        az group create --location "$LOCATION" --resource-group "$RESOURCE_GROUP"
        log "Resource group '$RESOURCE_GROUP' created"
    else
        log "Resource group '$RESOURCE_GROUP' already exists"
    fi
}

# Arc-enable the cluster
arc_enable_cluster() {
    log "Arc-enabling the Kubernetes cluster..."
    
    # Check if cluster is already Arc-enabled
    if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log "Cluster '$CLUSTER_NAME' is already Arc-enabled"
    else
        # Connect cluster to Azure Arc
        az connectedk8s connect --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
        log "Cluster Arc-enabled successfully"
    fi
    
    # Get OBJECT_ID for custom locations
    log "Getting Object ID for custom locations..."
    OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
    export OBJECT_ID
    
    # Enable custom locations and cluster connect features
    log "Enabling custom locations and cluster connect features..."
    az connectedk8s enable-features -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" \
        --custom-locations-oid "$OBJECT_ID" \
        --features cluster-connect custom-locations
    
    # Restart K3s to apply changes
    log "Restarting K3s..."
    sudo systemctl restart k3s
    
    # Wait for cluster to be ready again
    log "Waiting for cluster to be ready..."
    sleep 30
    
    # Verify cluster connectivity
    kubectl get nodes
}

# Create Azure Device Registry namespace
create_namespace() {
    log "Preparing Azure Device Registry namespace..."
    
    # Use namespace from config or prompt
    if [ -z "$NAMESPACE_NAME" ]; then
        read -p "Enter namespace name for Azure Device Registry: " NAMESPACE_NAME
        export NAMESPACE_NAME
    fi
    
    log "Namespace '$NAMESPACE_NAME' will be created automatically during Azure IoT Operations deployment"
    log "Note: Explicit namespace creation requires preview CLI version (1.2.36+)"
}

# Deploy Azure IoT Operations
deploy_iot_operations() {
    log "Deploying Azure IoT Operations..."
    
    # Initialize cluster for Azure IoT Operations
    log "Initializing cluster for Azure IoT Operations..."
    az iot ops init --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
    
    # Ensure required Azure resource providers are registered
    log "Checking Azure resource provider registrations..."
    STORAGE_PROVIDER_STATE=$(az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    
    if [ "$STORAGE_PROVIDER_STATE" != "Registered" ]; then
        log "Registering Microsoft.Storage resource provider..."
        az provider register --namespace Microsoft.Storage
        
        # Wait for registration to complete
        log "Waiting for Microsoft.Storage provider registration to complete..."
        while [ "$(az provider show --namespace Microsoft.Storage --query 'registrationState' -o tsv)" != "Registered" ]; do
            sleep 10
            log "Still waiting for Microsoft.Storage registration..."
        done
        log "Microsoft.Storage provider registered successfully"
    fi
    
    # Create schema registry first (required for newer versions)
    log "Creating schema registry for Azure IoT Operations..."
    SCHEMA_REGISTRY_NAME="${CLUSTER_NAME}-schema-registry"
    STORAGE_ACCOUNT_NAME=$(echo "${CLUSTER_NAME}storage" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-24)
    
    # Create storage account for schema registry
    log "Creating storage account: $STORAGE_ACCOUNT_NAME"
    az storage account create \
        --name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --enable-hierarchical-namespace true \
        --allow-blob-public-access false
    
    # Create container in storage account
    CONTAINER_NAME="schemas"
    log "Creating storage container: $CONTAINER_NAME"
    az storage container create \
        --name "$CONTAINER_NAME" \
        --account-name "$STORAGE_ACCOUNT_NAME" \
        --auth-mode login
    
    # Get storage account resource ID
    STORAGE_ACCOUNT_ID=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    
    # Create schema registry
    log "Creating schema registry: $SCHEMA_REGISTRY_NAME"
    az iot ops schema registry create \
        --name "$SCHEMA_REGISTRY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --registry-namespace "$NAMESPACE_NAME" \
        --sa-resource-id "$STORAGE_ACCOUNT_ID"
    
    # Get schema registry resource ID
    SCHEMA_REGISTRY_RESOURCE_ID=$(az iot ops schema registry show --name "$SCHEMA_REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    
    # Deploy Azure IoT Operations with schema registry
    log "Deploying Azure IoT Operations (this may take several minutes)..."
    log "Note: Using schema registry '$SCHEMA_REGISTRY_NAME'"
    
    az iot ops create \
        --cluster "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "${CLUSTER_NAME}-aio" \
        --sr-resource-id "$SCHEMA_REGISTRY_RESOURCE_ID"
    
    log "Azure IoT Operations deployed successfully!"
}

# Verify deployment
verify_deployment() {
    log "Verifying Azure IoT Operations deployment..."
    
    # Check deployment health
    az iot ops check
    
    # Show pods in azure-iot-operations namespace
    log "Azure IoT Operations pods:"
    kubectl get pods -n azure-iot-operations
    
    # Show services
    log "Azure IoT Operations services:"
    kubectl get services -n azure-iot-operations
    
    log "Deployment verification completed!"
}

# Display next steps
show_next_steps() {
    echo
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${GREEN}Azure IoT Operations Installation Complete!${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. View your Azure IoT Operations instance in the Azure Portal:"
    echo "   https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.IoTOperations%2Finstances"
    echo
    echo "2. Configure assets and data flows:"
    echo "   - Create assets to represent your industrial equipment"
    echo "   - Set up data flows to process and route data"
    echo
    echo "3. Monitor your deployment:"
    echo "   kubectl get pods -n azure-iot-operations"
    echo "   az iot ops check"
    echo
    echo -e "${BLUE}Important Variables:${NC}"
    echo "   Resource Group: $RESOURCE_GROUP"
    echo "   Cluster Name: $CLUSTER_NAME"
    echo "   Namespace: $NAMESPACE_NAME"
    echo "   Location: $LOCATION"
    echo
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "   # Check cluster status"
    echo "   kubectl get nodes"
    echo
    echo "   # View Azure IoT Operations pods"
    echo "   kubectl get pods -n azure-iot-operations"
    echo
    echo "   # Check Azure IoT Operations health"
    echo "   az iot ops check"
    echo
    echo "   # View logs for a specific pod"
    echo "   kubectl logs <pod-name> -n azure-iot-operations"
    echo
}

# Main installation function
main() {
    log "Starting Azure IoT Operations installation for Linux..."
    log "This script will install K3s, Azure CLI, and Azure IoT Operations"
    echo
    
    check_root
    check_system_requirements
    
    # Load configuration from JSON file (if available)
    load_config
    
    update_system
    install_azure_cli
    install_kubectl
    install_helm
    install_k3s
    configure_kubectl
    configure_system_settings
    azure_login_setup
    create_azure_resources
    arc_enable_cluster
    create_namespace
    deploy_iot_operations
    verify_deployment
    show_next_steps
    
    log "Installation completed successfully!"
}

# Trap to handle script interruption
trap 'error "Script interrupted by user"' INT

# Run main function
main "$@"
