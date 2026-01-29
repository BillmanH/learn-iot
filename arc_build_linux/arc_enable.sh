#!/bin/bash

# ============================================================================
# Azure IoT Operations - Arc Enable Script
# ============================================================================
# This script connects the K3s cluster to Azure Arc.
# Run this AFTER installer.sh and AFTER the resource group exists in Azure.
#
# Prerequisites:
#   - installer.sh has completed successfully
#   - Azure CLI installed (this script will install if missing)
#   - aio_config.json configured with Azure settings
#   - Resource group exists (or this script can create it)
#
# Usage:
#   ./arc_enable.sh [OPTIONS]
#
# Options:
#   --dry-run           Show what would be done without making changes
#   --config FILE       Use specific configuration file (default: ../config/aio_config.json)
#   --help              Show this help message
#
# Author: Azure IoT Operations Team
# Date: January 2026
# Version: 1.0.0
# ============================================================================

set -e  # Exit on any error
set -o pipefail  # Catch errors in pipes

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
CONFIG_FILE="${CONFIG_DIR}/aio_config.json"
CLUSTER_INFO_FILE="${CONFIG_DIR}/cluster_info.json"
DRY_RUN=false

LOG_FILE="${SCRIPT_DIR}/arc_enable_$(date +'%Y%m%d_%H%M%S').log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables (loaded from aio_config.json)
CLUSTER_NAME=""
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""
LOCATION=""

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

setup_logging() {
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    echo "============================================================================"
    echo "Azure IoT Operations - Arc Enable Script"
    echo "============================================================================"
    echo "Log file: $LOG_FILE"
    echo "Started: $(date)"
    echo ""
}

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

info() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

show_help() {
    echo "Azure IoT Operations - Arc Enable Script"
    echo ""
    echo "Usage: ./arc_enable.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run           Show what would be done without making changes"
    echo "  --config FILE       Use specific configuration file"
    echo "  --help              Show this help message"
    echo ""
    echo "This script connects your K3s cluster to Azure Arc."
    echo "Run this after installer.sh completes and your Azure resource group exists."
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

load_configuration() {
    log "Loading configuration..."
    
    # Check for aio_config.json
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Configuration file not found: $CONFIG_FILE
        
Please create aio_config.json with your Azure settings:
  cp ${CONFIG_DIR}/aio_config.json.template ${CONFIG_FILE}
  
Then edit it with your subscription, resource group, and cluster name."
    fi
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        log "Installing jq for JSON parsing..."
        sudo apt-get update && sudo apt-get install -y jq
    fi
    
    # Load values from aio_config.json
    CLUSTER_NAME=$(jq -r '.azure.cluster_name // empty' "$CONFIG_FILE")
    RESOURCE_GROUP=$(jq -r '.azure.resource_group // empty' "$CONFIG_FILE")
    SUBSCRIPTION_ID=$(jq -r '.azure.subscription_id // empty' "$CONFIG_FILE")
    LOCATION=$(jq -r '.azure.location // "eastus"' "$CONFIG_FILE")
    
    # Validate required fields
    if [ -z "$CLUSTER_NAME" ]; then
        error "cluster_name not found in $CONFIG_FILE"
    fi
    
    if [ -z "$RESOURCE_GROUP" ]; then
        error "resource_group not found in $CONFIG_FILE"
    fi
    
    if [ -z "$SUBSCRIPTION_ID" ]; then
        error "subscription_id not found in $CONFIG_FILE"
    fi
    
    echo ""
    echo -e "${CYAN}Configuration:${NC}"
    echo "  Cluster Name:   $CLUSTER_NAME"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Subscription:   $SUBSCRIPTION_ID"
    echo "  Location:       $LOCATION"
    echo ""
    
    success "Configuration loaded"
}

# ============================================================================
# PREREQUISITES
# ============================================================================

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl not found. Please run installer.sh first."
    fi
    success "kubectl is available"
    
    # Check if cluster is accessible
    if ! kubectl get nodes &> /dev/null; then
        error "Cannot access Kubernetes cluster. Is K3s running?
        
Check with: sudo systemctl status k3s
Restart with: sudo systemctl restart k3s"
    fi
    success "Kubernetes cluster is accessible"
    
    # Check/install Azure CLI
    if ! command -v az &> /dev/null; then
        log "Azure CLI not found. Installing..."
        
        if [ "$DRY_RUN" = true ]; then
            info "[DRY-RUN] Would install Azure CLI"
        else
            curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
        fi
    fi
    success "Azure CLI is available"
    
    # Check/install connectedk8s extension
    if ! az extension show --name connectedk8s &> /dev/null; then
        log "Installing Azure CLI connectedk8s extension..."
        
        if [ "$DRY_RUN" = true ]; then
            info "[DRY-RUN] Would install connectedk8s extension"
        else
            az extension add --name connectedk8s --upgrade -y
        fi
    fi
    success "connectedk8s extension is available"
    
    success "All prerequisites met"
}

# ============================================================================
# AZURE AUTHENTICATION
# ============================================================================

azure_login() {
    log "Checking Azure authentication..."
    
    # Check if already logged in
    if az account show &> /dev/null; then
        CURRENT_USER=$(az account show --query user.name -o tsv)
        CURRENT_SUB=$(az account show --query name -o tsv)
        success "Already logged in as: $CURRENT_USER"
        info "Current subscription: $CURRENT_SUB"
    else
        log "Not logged into Azure. Starting login..."
        
        if [ "$DRY_RUN" = true ]; then
            info "[DRY-RUN] Would run: az login"
        else
            az login
        fi
    fi
    
    # Set the correct subscription
    log "Setting subscription to: $SUBSCRIPTION_ID"
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would set subscription: $SUBSCRIPTION_ID"
    else
        az account set --subscription "$SUBSCRIPTION_ID"
        success "Subscription set to: $(az account show --query name -o tsv)"
    fi
}

# ============================================================================
# RESOURCE GROUP CHECK
# ============================================================================

check_resource_group() {
    log "Checking if resource group exists: $RESOURCE_GROUP"
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would check for resource group: $RESOURCE_GROUP"
        return
    fi
    
    RG_EXISTS=$(az group exists --name "$RESOURCE_GROUP")
    
    if [ "$RG_EXISTS" = "true" ]; then
        success "Resource group exists: $RESOURCE_GROUP"
    else
        echo ""
        echo -e "${YELLOW}============================================================================${NC}"
        echo -e "${YELLOW}RESOURCE GROUP DOES NOT EXIST${NC}"
        echo -e "${YELLOW}============================================================================${NC}"
        echo ""
        echo "The resource group '$RESOURCE_GROUP' does not exist in Azure."
        echo ""
        echo "Options:"
        echo "  1. Create it now (requires Contributor role on subscription)"
        echo "  2. Exit and create it manually or via External-Configurator.ps1"
        echo ""
        read -p "Create resource group now? (y/N): " CREATE_RG
        
        if [[ "$CREATE_RG" =~ ^[Yy]$ ]]; then
            log "Creating resource group: $RESOURCE_GROUP in $LOCATION"
            az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
            success "Resource group created: $RESOURCE_GROUP"
        else
            echo ""
            echo "To create the resource group manually, run:"
            echo "  az group create --name $RESOURCE_GROUP --location $LOCATION"
            echo ""
            echo "Or run External-Configurator.ps1 from Windows first to create Azure resources."
            echo ""
            error "Cannot continue without resource group"
        fi
    fi
}

# ============================================================================
# ARC ENABLE
# ============================================================================

arc_enable_cluster() {
    log "Connecting cluster to Azure Arc..."
    
    # Check if already Arc-enabled
    EXISTING_ARC=$(az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_ARC" ]; then
        success "Cluster '$CLUSTER_NAME' is already Arc-enabled"
        info "Connectivity status: $(echo "$EXISTING_ARC" | jq -r '.connectivityStatus')"
    else
        log "Arc-enabling cluster: $CLUSTER_NAME"
        
        if [ "$DRY_RUN" = true ]; then
            info "[DRY-RUN] Would run: az connectedk8s connect --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
        else
            az connectedk8s connect \
                --name "$CLUSTER_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --location "$LOCATION"
            
            success "Cluster connected to Azure Arc"
        fi
    fi
}

enable_arc_features() {
    log "Enabling Arc features (custom locations, cluster connect)..."
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would enable Arc features"
        return
    fi
    
    # Get the Custom Locations RP object ID
    CUSTOM_LOCATIONS_OID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv 2>/dev/null || echo "")
    
    if [ -n "$CUSTOM_LOCATIONS_OID" ]; then
        log "Enabling custom-locations and cluster-connect features..."
        az connectedk8s enable-features \
            --name "$CLUSTER_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --custom-locations-oid "$CUSTOM_LOCATIONS_OID" \
            --features cluster-connect custom-locations 2>/dev/null || true
        
        success "Custom locations enabled"
    else
        warn "Could not get Custom Locations RP object ID. Skipping feature enablement."
    fi
}

enable_oidc_workload_identity() {
    log "Enabling OIDC issuer and workload identity..."
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would enable OIDC and workload identity"
        return
    fi
    
    az connectedk8s update \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --enable-oidc-issuer \
        --enable-workload-identity 2>/dev/null || true
    
    success "OIDC issuer and workload identity enabled"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_arc_connection() {
    log "Verifying Arc connection..."
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would verify Arc connection"
        return
    fi
    
    # Wait a moment for status to update
    sleep 5
    
    ARC_STATUS=$(az connectedk8s show \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "connectivityStatus" -o tsv 2>/dev/null || echo "Unknown")
    
    echo ""
    echo -e "${CYAN}Arc Connection Status:${NC}"
    echo "  Cluster:    $CLUSTER_NAME"
    echo "  Status:     $ARC_STATUS"
    echo ""
    
    if [ "$ARC_STATUS" = "Connected" ]; then
        success "Cluster is connected to Azure Arc!"
    else
        warn "Cluster status is '$ARC_STATUS'. It may take a few minutes to fully connect."
        info "Check status with: az connectedk8s show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --query connectivityStatus"
    fi
}

# ============================================================================
# COMPLETION
# ============================================================================

display_completion() {
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}Arc Enablement Completed!${NC}"
    echo -e "${GREEN}============================================================================${NC}"
    echo ""
    echo "Your cluster '$CLUSTER_NAME' is now connected to Azure Arc."
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo ""
    echo "1. From your Windows management machine, run:"
    echo "   cd external_configuration"
    echo "   .\\External-Configurator.ps1"
    echo ""
    echo "2. This will deploy Azure IoT Operations to your cluster."
    echo ""
    echo "3. After deployment, run grant_entra_id_roles.ps1 to set up permissions:"
    echo "   .\\grant_entra_id_roles.ps1"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  Check Arc status:  az connectedk8s show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
    echo "  View Arc agents:   kubectl get pods -n azure-arc"
    echo "  Cluster proxy:     az connectedk8s proxy --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_arguments "$@"
    setup_logging
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}*** DRY-RUN MODE - No changes will be made ***${NC}"
        echo ""
    fi
    
    load_configuration
    check_prerequisites
    azure_login
    check_resource_group
    arc_enable_cluster
    enable_arc_features
    enable_oidc_workload_identity
    verify_arc_connection
    display_completion
    
    log "Arc enablement completed successfully!"
}

# Trap to handle script interruption
trap 'error "Script interrupted by user"' INT

# Run main function
main "$@"
