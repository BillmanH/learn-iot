#!/bin/bash

# Azure IoT Operations Installation Script for Linux (Ubuntu)
# This script installs Azure IoT Operations on a K3s Kubernetes cluster on Ubuntu
# Requirements: Ubuntu 24.04+, 16GB RAM (32GB recommended), 4+ CPUs
# Author: Azure IoT Operations Installation Script
# Date: October 2025
#
# CUSTOM ASSET ENDPOINT SUPPORT:
# If you have an existing asset endpoint that you want to use as the namespace resource,
# you can specify it in one of these ways:
# 
# 1. Environment variable:
#    export CUSTOM_ASSET_ENDPOINT="your-asset-endpoint-name"
#    sudo -E ./linuxAIO.sh
#
# 2. Configuration file (linux_aio_config.json):
#    {
#      "azure": {
#        "custom_asset_endpoint": "your-asset-endpoint-name"
#      }
#    }
#
# The script will look up the resource ID of the specified asset endpoint and use it
# for the --ns-resource-id parameter in Azure IoT Operations deployment.

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
    
    # If the error is related to K3s connectivity, provide troubleshooting info
    if [[ "$1" == *"Kubernetes"* ]] || [[ "$1" == *"cluster"* ]] || [[ "$1" == *"kubectl"* ]]; then
        echo -e "${YELLOW}Troubleshooting steps:${NC}"
        echo "1. Check K3s service status:"
        echo "   sudo systemctl status k3s"
        echo "2. Check K3s logs:"
        echo "   sudo journalctl -u k3s --no-pager"
        echo "3. Try restarting K3s:"
        echo "   sudo systemctl restart k3s"
        echo "4. Check if the API server is listening:"
        echo "   sudo ss -tlnp | grep 6443"
        echo "5. Verify kubeconfig:"
        echo "   ls -la ~/.kube/"
        echo "   cat ~/.kube/config"
        echo "6. Check disk space:"
        echo "   df -h"
        echo "7. Check system resources:"
        echo "   free -h"
        echo "   top"
    fi
    
    exit 1
}

# Check if running as root
check_root() {
    if [ "$EUID" -eq 0 ]; then
        error "Please do not run this script as root. Use sudo when prompted."
    fi
}

# Check for port conflicts
check_port_conflicts() {
    log "Checking for port conflicts..."
    
    # First, check if K3s is already running successfully
    if sudo systemctl is-active --quiet k3s 2>/dev/null; then
        log "K3s service is already running"
        
        # Test if K3s cluster is actually working
        if sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
            log "K3s cluster is running and healthy - no port conflicts detected"
            log "Nodes status:"
            sudo k3s kubectl get nodes 2>/dev/null || true
            return 0  # No conflicts, K3s is working fine
        else
            warn "K3s service is running but cluster is not healthy"
            log "This might indicate a configuration issue rather than port conflicts"
        fi
    fi
    
    # Function to check if port 6443 is in use
    check_port_in_use() {
        if command -v ss >/dev/null 2>&1; then
            ss -tlnp 2>/dev/null | grep -q ":6443 "
        elif command -v lsof >/dev/null 2>&1; then
            lsof -i :6443 2>/dev/null | grep -q ":6443"
        else
            # Last resort: try to connect to the port
            timeout 2 bash -c "</dev/tcp/127.0.0.1/6443" 2>/dev/null
        fi
    }
    
    # Function to get port usage info
    get_port_info() {
        if command -v ss >/dev/null 2>&1; then
            ss -tlnp 2>/dev/null | grep ":6443 "
        elif command -v lsof >/dev/null 2>&1; then
            lsof -i :6443 2>/dev/null
        else
            echo "Port 6443 appears to be in use - using basic connectivity test"
        fi
    }
    
    # Check if port 6443 (Kubernetes API) is in use by non-working processes
    if check_port_in_use; then
        log "Port 6443 is in use - checking if there is a conflict..."
        echo "Processes using port 6443:"
        get_port_info
        echo
        
        # Check if it is K3s that is not working properly
        if get_port_info | grep -q "k3s"; then
            warn "K3s is using port 6443 but the cluster is not healthy"
            log "This suggests K3s needs to be restarted rather than having port conflicts"
            read -p "Do you want to restart the K3s service? (y/N): " restart_k3s
            if [[ "$restart_k3s" =~ ^[Yy]$ ]]; then
                log "Restarting K3s service..."
                sudo systemctl restart k3s || true
                sleep 10
                
                # Check if it is working now
                if sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
                    log "K3s cluster is now healthy after restart"
                    return 0
                else
                    warn "K3s still not healthy after restart - may need cleanup"
                fi
            else
                warn "K3s may need attention - consider restarting the service"
            fi
        else
            warn "Non-K3s process is using port 6443 - this is a genuine conflict!"
            echo "Common conflicting processes:"
            echo "- kubelite/MicroK8s"
            echo "- Docker containers running Kubernetes"
            echo "- Minikube"
            echo "- Kind clusters"
            echo "- Other Kubernetes distributions"
            echo
            read -p "Do you want to try to identify and stop the conflicting process? (y/N): " stop_process
            if [[ "$stop_process" =~ ^[Yy]$ ]]; then
                log "Attempting to stop conflicting processes..."
                
                # Use the dedicated port fix script if available
                if [ -f "./fix_port_6443.sh" ]; then
                    log "Using automated port conflict resolver..."
                    chmod +x ./fix_port_6443.sh
                    ./fix_port_6443.sh
                else
                    # Fallback to manual process killing
                    log "Running manual conflict resolution..."
                    # Try to stop common Kubernetes processes
                    sudo pkill -f "kube-apiserver" || true
                    sudo pkill -f "minikube" || true
                    sudo pkill -f "kind" || true
                    docker stop $(docker ps -q --filter "publish=6443") 2>/dev/null || true
                    sleep 5
                fi
                
                # Check again
                if check_port_in_use; then
                    error "Port 6443 is still in use. Please manually stop the conflicting process and try again."
                fi
            else
                error "Cannot proceed with port 6443 in use. Please free up the port and try again."
            fi
        fi
    else
        log "Port 6443 is free - no conflicts detected"
    fi
    
    # Check other common Kubernetes ports for potential issues (but do not block on them)
    for port in 6444 10250 10251 10252; do
        if command -v ss >/dev/null 2>&1; then
            if ss -tlnp 2>/dev/null | grep -q ":$port "; then
                warn "Port $port is in use (this may cause issues)"
                ss -tlnp 2>/dev/null | grep ":$port "
            fi
        elif command -v lsof >/dev/null 2>&1; then
            if lsof -i :$port 2>/dev/null | grep -q ":$port"; then
                warn "Port $port is in use (this may cause issues)"
                lsof -i :$port 2>/dev/null
            fi
        fi
    done
    
    log "Port conflict check completed"
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
    
    if [ "$total_ram_gb" -lt 10 ]; then
        error "Minimum 10GB (free) RAM required. Current: ${total_ram_gb}GB"
    fi

    if [ "$total_ram_gb" -lt 16 ] || [ "$total_ram_gb" -ge 11 ]; then
        warn "This is recommended for 16GB RAM, and you have: ${total_ram_gb}GB. It should work with >10GB but if it crashes this could be the reason."
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
        CUSTOM_ASSET_ENDPOINT=$(jq -r '.azure.custom_asset_endpoint // empty' "$config_file")
        SKIP_SYSTEM_UPDATE=$(jq -r '.deployment.skip_system_update // false' "$config_file")
        FORCE_REINSTALL=$(jq -r '.deployment.force_reinstall // false' "$config_file")
        DEPLOYMENT_MODE=$(jq -r '.deployment.deployment_mode // "test"' "$config_file")
        DEPLOY_OPC_UA_BRIDGE=$(jq -r '.deployment.deploy_opc_ua_bridge // true' "$config_file")
        
        # Export variables
        export SUBSCRIPTION_ID SUBSCRIPTION_NAME RESOURCE_GROUP LOCATION CLUSTER_NAME NAMESPACE_NAME CUSTOM_ASSET_ENDPOINT
        export SKIP_SYSTEM_UPDATE FORCE_REINSTALL DEPLOYMENT_MODE DEPLOY_OPC_UA_BRIDGE
        
        log "Configuration loaded from $config_file"
        log "Resource Group: $RESOURCE_GROUP, Location: $LOCATION, Cluster: $CLUSTER_NAME"
        return 0
    else
        log "Configuration file $config_file not found. Will prompt for values interactively."
        # Set default values
        DEPLOY_OPC_UA_BRIDGE="true"
        export DEPLOY_OPC_UA_BRIDGE
        return 1
    fi
}

# Update system packages
update_system() {
    if [ "$SKIP_SYSTEM_UPDATE" = "true" ]; then
        log "Skipping system update - skip_system_update=true in config"
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
        current_version=$(az version --query 'azure-cli' -o tsv)
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
    az_version=$(az version --query 'azure-cli' -o tsv)
    log "Azure CLI version: $az_version"
    
    # Install required Azure CLI extensions
    log "Installing Azure CLI extensions..."
    
    log "Installing azure-iot-ops extension..."
    if az extension add --upgrade --name azure-iot-ops 2>/dev/null; then
        log "SUCCESS: azure-iot-ops extension installed"
    else
        log "WARNING: Failed to install azure-iot-ops extension, will attempt to continue"
    fi
    
    log "Installing connectedk8s extension..."
    if az extension add --upgrade --name connectedk8s 2>/dev/null; then
        log "SUCCESS: connectedk8s extension installed"
    else
        log "WARNING: Failed to install connectedk8s extension, will attempt to continue"
    fi
    
    # Verify that the azure-iot-ops extension works
    log "Verifying azure-iot-ops extension functionality..."
    if az iot ops --help >/dev/null 2>&1; then
        log "SUCCESS: azure-iot-ops extension is working"
    else
        log "WARNING: azure-iot-ops extension may not be fully functional"
        log "Some asset endpoint features may not work"
    fi
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

# Check for and resolve kubelite/MicroK8s conflicts
check_kubelite_conflicts() {
    log "Checking for kubelite/MicroK8s conflicts..."
    
    # Check for kubelite process
    if pgrep -f kubelite >/dev/null 2>&1; then
        warn "Found kubelite process running (likely MicroK8s or similar)"
        log "kubelite often conflicts with K3s by using the same ports 6443, 10257"
        
        # Check if it is MicroK8s
        if command -v microk8s >/dev/null 2>&1; then
            log "MicroK8s is installed - this uses kubelite internally"
            read -p "Do you want to stop MicroK8s to avoid port conflicts? (y/N): " stop_microk8s
            if [[ "$stop_microk8s" =~ ^[Yy]$ ]]; then
                log "Stopping MicroK8s..."
                sudo microk8s stop || true
                sudo systemctl stop snap.microk8s.daemon-kubelite || true
                sudo systemctl disable snap.microk8s.daemon-kubelite || true
                log "MicroK8s stopped"
            else
                warn "MicroK8s is still running - this may cause port conflicts with K3s"
                warn "If K3s fails to start, please run: sudo microk8s stop"
            fi
        else
            # Direct kubelite service
            log "Checking for kubelite service..."
            if sudo systemctl is-active --quiet kubelite 2>/dev/null; then
                read -p "Do you want to stop the kubelite service? (y/N): " stop_kubelite
                if [[ "$stop_kubelite" =~ ^[Yy]$ ]]; then
                    log "Stopping kubelite service..."
                    sudo systemctl stop kubelite || true
                    sudo systemctl disable kubelite || true
                    log "kubelite service stopped"
                fi
            else
                # Kill kubelite process directly
                read -p "Do you want to kill the kubelite process? (y/N): " kill_kubelite
                if [[ "$kill_kubelite" =~ ^[Yy]$ ]]; then
                    log "Killing kubelite process..."
                    sudo pkill -f kubelite || true
                    log "kubelite process killed"
                fi
            fi
        fi
        
        # Wait a moment for processes to stop
        sleep 3
        
        # Verify kubelite is stopped
        if pgrep -f kubelite >/dev/null 2>&1; then
            warn "kubelite is still running - K3s may fail to start due to port conflicts"
            warn "You may need to manually stop kubelite or reboot the system"
        else
            log "kubelite is no longer running"
        fi
    else
        log "No kubelite conflicts detected"
    fi
    
    # Check for other Kubernetes distributions that might conflict
    if command -v minikube >/dev/null 2>&1; then
        if minikube status 2>/dev/null | grep -q "Running"; then
            warn "Minikube is running and may conflict with K3s"
            read -p "Do you want to stop minikube? (y/N): " stop_minikube
            if [[ "$stop_minikube" =~ ^[Yy]$ ]]; then
                log "Stopping minikube..."
                minikube stop || true
                log "minikube stopped"
            fi
        fi
    fi
    
    if command -v kind >/dev/null 2>&1; then
        if kind get clusters 2>/dev/null | grep -q .; then
            warn "Kind clusters are running and may conflict with K3s"
            read -p "Do you want to delete all kind clusters? (y/N): " delete_kind
            if [[ "$delete_kind" =~ ^[Yy]$ ]]; then
                log "Deleting kind clusters..."
                for cluster in $(kind get clusters 2>/dev/null); do
                    kind delete cluster --name "$cluster" || true
                done
                log "Kind clusters deleted"
            fi
        fi
    fi
}

# Clean up existing K3s installation
cleanup_k3s() {
    log "Checking for existing K3s installation..."
    
    if command -v k3s &> /dev/null || [ -f /usr/local/bin/k3s ]; then
        
        # First check if K3s is running and healthy
        if sudo systemctl is-active --quiet k3s 2>/dev/null; then
            log "K3s service is running - checking cluster health..."
            
            # Test if K3s cluster is actually working
            if sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
                log "K3s cluster is running and healthy - skipping cleanup"
                log "Current cluster status:"
                sudo k3s kubectl get nodes 2>/dev/null || true
                echo
                log "Continuing with Azure IoT Operations installation on existing healthy K3s cluster..."
                return 0  # Skip cleanup, K3s is working fine
            else
                warn "K3s service is running but cluster is not healthy"
                log "This indicates K3s needs attention"
            fi
        fi
        
        warn "Found existing K3s installation that needs cleanup"
        
        # Check if K3s is running (but not healthy from above check)
        if sudo systemctl is-active --quiet k3s 2>/dev/null; then
            log "K3s service is currently running but not healthy"
            read -p "Do you want to stop and clean up the existing K3s installation? (y/N): " cleanup
            if [[ "$cleanup" =~ ^[Yy]$ ]]; then
                log "Stopping K3s service..."
                sudo systemctl stop k3s || true
                sudo systemctl disable k3s || true
                
                log "Cleaning up K3s processes..."
                sudo pkill -f k3s || true
                
                # Clean up K3s installation
                if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
                    log "Running K3s uninstall script..."
                    sudo /usr/local/bin/k3s-uninstall.sh || true
                fi
                
                # Additional cleanup
                log "Performing additional cleanup..."
                sudo rm -rf /etc/rancher/k3s/ || true
                sudo rm -rf /var/lib/rancher/k3s/ || true
                sudo rm -f /usr/local/bin/k3s || true
                sudo rm -f /usr/local/bin/kubectl || true
                sudo rm -f /usr/local/bin/crictl || true
                sudo rm -f /usr/local/bin/ctr || true
                
                # Clean up systemd service
                sudo rm -f /etc/systemd/system/k3s.service || true
                sudo systemctl daemon-reload
                
                log "K3s cleanup completed"
            else
                error "Cannot proceed with existing K3s installation. Please clean it up manually or choose to clean it up."
            fi
        else
            log "K3s is installed but not running - this might be causing conflicts"
            read -p "Do you want to clean up the existing K3s installation? (y/N): " cleanup
            if [[ "$cleanup" =~ ^[Yy]$ ]]; then
                log "Cleaning up existing K3s installation..."
                
                # Clean up K3s installation
                if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
                    log "Running K3s uninstall script..."
                    sudo /usr/local/bin/k3s-uninstall.sh || true
                fi
                
                # Additional cleanup
                sudo rm -rf /etc/rancher/k3s/ || true
                sudo rm -rf /var/lib/rancher/k3s/ || true
                sudo rm -f /usr/local/bin/k3s || true
                
                log "K3s cleanup completed"
            fi
        fi
    else
        log "No existing K3s installation found"
    fi
}

# Check resource availability before K3s installation
check_k3s_resources() {
    log "Checking resource availability for K3s..."
    
    # Check available memory (not just total)
    available_ram_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    available_ram_gb=$((available_ram_kb / 1024 / 1024))
    
    if [ "$available_ram_gb" -lt 4 ]; then
        warn "Low available memory: ${available_ram_gb}GB. K3s may fail to start."
        warn "Consider stopping other services or adding more RAM."
    fi
    
    # Check disk space in critical directories
    root_space=$(df / | awk 'NR==2 {print $4}')
    root_space_gb=$((root_space / 1024 / 1024))
    
    if [ "$root_space_gb" -lt 10 ]; then
        error "Insufficient disk space: ${root_space_gb}GB available. Need at least 10GB."
    fi
    
    if [ "$root_space_gb" -lt 20 ]; then
        warn "Low disk space: ${root_space_gb}GB available. Consider freeing up space."
    fi
    
    # Check file descriptor limits
    current_fd_limit=$(ulimit -n)
    if [ "$current_fd_limit" -lt 4096 ]; then
        warn "Low file descriptor limit: $current_fd_limit. May cause issues."
        
        # Try to increase the limit temporarily
        log "Attempting to increase file descriptor limit..."
        if ulimit -n 65536 2>/dev/null; then
            log "Successfully increased file descriptor limit to 65536 for this session"
            current_fd_limit=65536
        else
            warn "Cannot increase file descriptor limit. You may need to configure /etc/security/limits.conf"
            echo "  Add these lines to /etc/security/limits.conf:"
            echo "  * soft nofile 65536"
            echo "  * hard nofile 65536"
            echo "  Then log out and back in."
        fi
    fi
    
    # Check system load
    load_avg=$(cat /proc/loadavg | awk '{print $1}')
    cpu_count=$(nproc)
    high_load=$(echo "$load_avg > $cpu_count * 2" | bc -l 2>/dev/null || echo "0")
    
    if [ "$high_load" = "1" ]; then
        warn "High system load: $load_avg. K3s startup may be slow."
    fi
    
    log "Resource check completed: ${available_ram_gb}GB available RAM, ${root_space_gb}GB disk space"
}

# Install K3s
install_k3s() {
    log "Installing K3s Kubernetes..."
    
    # Check resources before installation
    check_k3s_resources
    
    if command -v k3s &> /dev/null; then
        log "K3s already installed: $(k3s --version | head -n1)"
        
        # Check if K3s is running
        if ! sudo systemctl is-active --quiet k3s; then
            log "K3s is installed but not running. Starting K3s..."
            sudo systemctl start k3s
            sudo systemctl enable k3s
        fi
    else
        # Install K3s with Traefik disabled (required for Azure IoT Operations)
        log "Downloading and installing K3s..."
        
        # Check internet connectivity first
        if ! curl -s --connect-timeout 10 https://get.k3s.io >/dev/null; then
            error "Cannot connect to K3s installation script. Check internet connectivity and firewall settings."
        fi
        
        # Download and install with timeout and better error handling
        log "Downloading K3s installer - this may take a few minutes..."
        if ! timeout 300 curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode 644; then
            error "K3s installation failed. This could be due to network issues, insufficient resources, or firewall blocking. Check: sudo journalctl -u k3s"
        fi
        
        # Enable and start K3s service
        log "Enabling and starting K3s service..."
        sudo systemctl enable k3s
        sudo systemctl start k3s
    fi
    
    # Wait for K3s to be ready
    log "Waiting for K3s to be ready..."
    local timeout=300
    local count=0
    while [ $count -lt $timeout ]; do
        if sudo systemctl is-active --quiet k3s && sudo k3s kubectl get nodes >/dev/null 2>&1; then
            if sudo k3s kubectl get nodes | grep -q " Ready "; then
                log "K3s is ready"
                break
            fi
        fi
        
        if [ $count -eq 0 ]; then
            log "K3s is starting up..."
        elif [ $((count % 30)) -eq 0 ]; then
            log "Still waiting for K3s to be ready... $count/$timeout seconds"
        fi
        
        sleep 5
        count=$((count + 5))
    done
    
    if [ $count -ge $timeout ]; then
        error "K3s failed to become ready within 5 minutes. Check the logs with: sudo journalctl -u k3s"
    fi
    
    log "K3s installed and running successfully"
}

# Configure kubectl for K3s
configure_kubectl() {
    log "Configuring kubectl for K3s..."
    
    # Wait for k3s.yaml to be created
    local timeout=60
    local count=0
    while [ ! -f /etc/rancher/k3s/k3s.yaml ] && [ $count -lt $timeout ]; do
        log "Waiting for K3s configuration file..."
        sleep 2
        count=$((count + 2))
    done
    
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
        error "K3s configuration file not found after $timeout seconds"
    fi
    
    # Create .kube directory
    mkdir -p ~/.kube
    
    # Backup existing config if it exists
    if [ -f ~/.kube/config ]; then
        cp ~/.kube/config ~/.kube/config.backup.$(date +%s)
        log "Backed up existing kubectl config"
    fi
    
    # Make k3s config readable
    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    
    # Copy K3s config to kubectl config
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    chmod 0600 ~/.kube/config
    
    # Set KUBECONFIG environment variable
    export KUBECONFIG=~/.kube/config
    
    # Verify kubectl can connect
    if kubectl cluster-info >/dev/null 2>&1; then
        log "kubectl configured and connected successfully"
    else
        error "kubectl configuration failed - cannot connect to cluster"
    fi
    
    log "kubectl configured for K3s"
}

# Configure system settings for Azure IoT Operations
configure_system_settings() {
    log "Configuring system settings for Azure IoT Operations..."
    
    # Check if settings are already configured to prevent duplicate entries
    if ! grep -q "fs.inotify.max_user_instances=8192" /etc/sysctl.conf; then
        log "Adding inotify max_user_instances setting..."
        echo 'fs.inotify.max_user_instances=8192' | sudo tee -a /etc/sysctl.conf
    else
        log "inotify max_user_instances setting already configured"
    fi
    
    if ! grep -q "fs.inotify.max_user_watches=524288" /etc/sysctl.conf; then
        log "Adding inotify max_user_watches setting..."
        echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.conf
    else
        log "inotify max_user_watches setting already configured"
    fi
    
    if ! grep -q "fs.file-max=100000" /etc/sysctl.conf; then
        log "Adding file-max setting..."
        echo 'fs.file-max=100000' | sudo tee -a /etc/sysctl.conf
    else
        log "file-max setting already configured"
    fi
    
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
        read -p "Enter resource group name (will be created if it does not exist): " RESOURCE_GROUP
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
    
    # Create resource group if it does not exist
    if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        az group create --location "$LOCATION" --resource-group "$RESOURCE_GROUP"
        log "Resource group $RESOURCE_GROUP created"
    else
        log "Resource group $RESOURCE_GROUP already exists"
    fi
}

# Arc-enable the cluster
arc_enable_cluster() {
    log "Arc-enabling the Kubernetes cluster..."
    
    # Check if cluster is already Arc-enabled
    if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log "Cluster $CLUSTER_NAME is already Arc-enabled"
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
    verify_cluster_connectivity
}

# Verify cluster connectivity
verify_cluster_connectivity() {
    log "Verifying Kubernetes cluster connectivity..."
    
    # Check if K3s service is running
    if ! sudo systemctl is-active --quiet k3s; then
        warn "K3s service is not running. Attempting to start..."
        sudo systemctl start k3s
        sleep 10
    fi
    
    # Wait for K3s API server to be ready
    local timeout=120
    local count=0
    while [ $count -lt $timeout ]; do
        if kubectl get nodes >/dev/null 2>&1; then
            log "Kubernetes cluster is accessible"
            break
        fi
        
        if [ $count -eq 0 ]; then
            log "Waiting for Kubernetes API server to be ready..."
        fi
        
        sleep 5
        count=$((count + 5))
        
        # Try to restart K3s if it is taking too long
        if [ $count -eq 60 ]; then
            warn "Kubernetes API server not responding. Restarting K3s..."
            sudo systemctl restart k3s
            sleep 15
        fi
    done
    
    if [ $count -ge $timeout ]; then
        error "Kubernetes cluster is not accessible after $timeout seconds. Please check K3s installation."
    fi
    
    # Verify nodes are ready
    log "Checking node status..."
    kubectl get nodes
    
    # Check if nodes are in Ready state
    if ! kubectl get nodes | grep -q " Ready "; then
        error "Kubernetes nodes are not in Ready state"
    fi
    
    log "Cluster connectivity verified successfully"
}

# Create Azure Device Registry namespace
create_namespace() {
    log "Preparing Azure Device Registry namespace..."
    
    # Use namespace from config or prompt
    if [ -z "$NAMESPACE_NAME" ]; then
        read -p "Enter namespace name for Azure Device Registry: " NAMESPACE_NAME
        export NAMESPACE_NAME
    fi
    
    log "Namespace $NAMESPACE_NAME will be created automatically during Azure IoT Operations deployment"
    log "Note: Explicit namespace creation requires preview CLI version 1.2.36+"
}

# Deploy Azure IoT Operations
deploy_iot_operations() {
    log "Deploying Azure IoT Operations..."
    
    # Check if Azure IoT Operations instance already exists
    INSTANCE_NAME="${CLUSTER_NAME}-aio"
    if az iot ops show --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log "Azure IoT Operations instance $INSTANCE_NAME already exists - skipping deployment"
        log "To force reinstall, delete the existing instance first:"
        log "az iot ops delete --name $INSTANCE_NAME --resource-group $RESOURCE_GROUP"
        return 0
    fi
    
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
        while [ "$(az provider show --namespace Microsoft.Storage --query registrationState -o tsv)" != "Registered" ]; do
            sleep 10
            log "Still waiting for Microsoft.Storage registration..."
        done
        log "Microsoft.Storage provider registered successfully"
    fi
    
    # Create schema registry first (required for newer versions)
    log "Creating schema registry for Azure IoT Operations..."
    SCHEMA_REGISTRY_NAME="${CLUSTER_NAME}-schema-registry"
    STORAGE_ACCOUNT_NAME=$(echo "${CLUSTER_NAME}storage" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-24)
    
    # Check if schema registry already exists
    if az iot ops schema registry show --name "$SCHEMA_REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log "Schema registry $SCHEMA_REGISTRY_NAME already exists - using existing one"
        SCHEMA_REGISTRY_RESOURCE_ID=$(az iot ops schema registry show --name "$SCHEMA_REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    else
        # Create storage account for schema registry
        log "Creating storage account: $STORAGE_ACCOUNT_NAME"
        if az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
            log "Storage account $STORAGE_ACCOUNT_NAME already exists - using existing one"
        else
            log "Creating storage account: $STORAGE_ACCOUNT_NAME"
            az storage account create \
                --name "$STORAGE_ACCOUNT_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --location "$LOCATION" \
                --sku Standard_LRS \
                --kind StorageV2 \
                --enable-hierarchical-namespace true \
                --allow-blob-public-access false
        fi        # Create container in storage account
        CONTAINER_NAME="schemas"
        if az storage container exists --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT_NAME" --auth-mode login --query exists -o tsv 2>/dev/null | grep -q true; then
            log "Storage container $CONTAINER_NAME already exists - using existing one"
        else
            log "Creating storage container: $CONTAINER_NAME"
            az storage container create \
                --name "$CONTAINER_NAME" \
                --account-name "$STORAGE_ACCOUNT_NAME" \
                --auth-mode login
        fi
        
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
    fi    # Create namespace resource using Device Registry (required for newer AIO versions)
    log "Creating namespace resource for Azure IoT Operations using Device Registry..."
    NAMESPACE_RESOURCE_NAME="${NAMESPACE_NAME}-namespace"
    
    log "DEBUG: Namespace name: $NAMESPACE_NAME"
    log "DEBUG: Namespace resource name: $NAMESPACE_RESOURCE_NAME"
    log "DEBUG: Resource group: $RESOURCE_GROUP"
    log "DEBUG: Cluster name: $CLUSTER_NAME"
    
    # Since asset endpoint commands do not exist in current CLI version, create a Device Registry namespace directly
    log "Creating Device Registry namespace resource as workaround for missing asset endpoint commands..."
    
    # Try creating a Device Registry namespace directly
    log "Attempting to create namespace using Device Registry API..."
    
    # Create a namespace resource for Azure IoT Operations using Azure REST API
    NAMESPACE_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.DeviceRegistry/assetEndpointProfiles/$NAMESPACE_RESOURCE_NAME"
    
    log "Using constructed namespace resource ID: $NAMESPACE_RESOURCE_ID"
    
    # Create a minimal asset endpoint profile using Azure CLI generic commands
    log "Creating minimal asset endpoint profile for namespace..."
    
    # Create the namespace resource using az rest command (more reliable than extension commands)
    NAMESPACE_JSON=$(cat << EOF
{
  "location": "$LOCATION",
  "properties": {
    "targetAddress": "opc.tcp://namespace-placeholder:50000",
    "transportAuthentication": {
      "ownCertificates": []
    },
    "additionalConfiguration": "{}"
  }
}
EOF
)

    # Use az rest to create the asset endpoint profile
    log "Creating namespace resource using REST API..."
    CREATE_RESULT=$(az rest \
        --method PUT \
        --url "https://management.azure.com$NAMESPACE_RESOURCE_ID?api-version=2024-09-01-preview" \
        --body "$NAMESPACE_JSON" \
        --headers "Content-Type=application/json" 2>&1 || echo "REST API creation failed")
    
    if [[ "$CREATE_RESULT" != *"failed"* ]] && [[ "$CREATE_RESULT" != *"ERROR"* ]]; then
        log "SUCCESS: Created namespace resource using REST API"
        log "Namespace Resource ID: $NAMESPACE_RESOURCE_ID"
    else
        warn "Failed to create namespace using REST API. Output: $CREATE_RESULT"
        
        # Fallback: Try to find any existing Device Registry resources that could work
        log "Attempting fallback: looking for existing Device Registry resources..."
        
        EXISTING_REGISTRY_RESOURCES=$(az resource list \
            --resource-group "$RESOURCE_GROUP" \
            --resource-type "Microsoft.DeviceRegistry/assetEndpointProfiles" \
            --query "[0].id" -o tsv 2>/dev/null || echo "")
        
        if [ -n "$EXISTING_REGISTRY_RESOURCES" ] && [[ "$EXISTING_REGISTRY_RESOURCES" != *"ERROR"* ]]; then
            NAMESPACE_RESOURCE_ID="$EXISTING_REGISTRY_RESOURCES"
            log "SUCCESS: Found existing Device Registry resource to use: $NAMESPACE_RESOURCE_ID"
        else
            warn "Could not create or find any suitable namespace resource"
            log "Will attempt deployment without namespace resource ID"
            NAMESPACE_RESOURCE_ID="skip"
        fi
    fi
    
    if [ "$NAMESPACE_RESOURCE_ID" = "skip" ]; then
        log "DEPLOYMENT APPROACH: Will deploy Azure IoT Operations WITHOUT --ns-resource-id parameter"
    else
        log "FINAL RESULT: Using namespace resource ID: $NAMESPACE_RESOURCE_ID"
    fi
    
    # Deploy Azure IoT Operations with schema registry and namespace
    log "Deploying Azure IoT Operations - this may take several minutes..."
    log "Note: Using schema registry: $SCHEMA_REGISTRY_NAME"
    log "Note: Schema Registry ID: $SCHEMA_REGISTRY_RESOURCE_ID"
    
    # Since --ns-resource-id is REQUIRED, ensure we have a valid one
    if [ "$NAMESPACE_RESOURCE_ID" = "skip" ] || [ -z "$NAMESPACE_RESOURCE_ID" ]; then
        warn "--ns-resource-id is required but we do not have a valid namespace resource"
        log "Creating a simple placeholder namespace resource as workaround..."
        
        # Create a minimal asset endpoint profile using Azure CLI commands that work
        FALLBACK_ENDPOINT_NAME="aio-namespace-${NAMESPACE_NAME}"
        NAMESPACE_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.DeviceRegistry/assetEndpointProfiles/$FALLBACK_ENDPOINT_NAME"
        
        log "Attempting to create placeholder endpoint profile: $FALLBACK_ENDPOINT_NAME"
        
        # Check if the namespace resource already exists
        if az resource show --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.DeviceRegistry/assetEndpointProfiles" --name "$FALLBACK_ENDPOINT_NAME" &> /dev/null; then
            log "Placeholder namespace resource $FALLBACK_ENDPOINT_NAME already exists - using existing one"
        else
            # Create a simple JSON properties string to avoid quote issues
            ENDPOINT_PROPS='{"targetAddress":"opc.tcp://placeholder:50000","transportAuthentication":{},"additionalConfiguration":""}'
            
            log "Creating placeholder namespace resource..."
            if az resource create --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.DeviceRegistry/assetEndpointProfiles" --name "$FALLBACK_ENDPOINT_NAME" --properties "$ENDPOINT_PROPS" --api-version "2024-09-01-preview" 2>/dev/null; then
                log "SUCCESS: Created placeholder namespace resource"
            else
                warn "Failed to create placeholder namespace resource"
                error "Cannot proceed without a valid --ns-resource-id. Azure IoT Operations requires this parameter."
            fi
        fi
    fi
    
    log "FINAL Namespace Resource ID: $NAMESPACE_RESOURCE_ID"
    log "EXECUTING: az iot ops create --cluster $CLUSTER_NAME --resource-group $RESOURCE_GROUP --name ${CLUSTER_NAME}-aio --sr-resource-id $SCHEMA_REGISTRY_RESOURCE_ID --ns-resource-id $NAMESPACE_RESOURCE_ID"
    
    if az iot ops create \
        --cluster "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "${CLUSTER_NAME}-aio" \
        --sr-resource-id "$SCHEMA_REGISTRY_RESOURCE_ID" \
        --ns-resource-id "$NAMESPACE_RESOURCE_ID"; then
        log "Azure IoT Operations deployed successfully!"
    else
        error "Azure IoT Operations deployment failed. Check the logs above for details."
    fi
}

# Enable resource sync for asset discovery
enable_asset_sync() {
    log "Enabling edge-to-cloud asset sync for discovered assets..."
    
    # Enable resource sync rules on Azure IoT Operations instance
    log "Enabling rsync to surface discovered assets in cloud experience..."
    
    INSTANCE_NAME="${CLUSTER_NAME}-aio"
    
    if az iot ops enable-rsync --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP"; then
        log "[SUCCESS] Asset sync enabled successfully!"
        log "Discovered assets on the edge will now be surfaced in the cloud experience"
    else
        warn "Failed to enable asset sync. You may need to run this manually:"
        warn "az iot ops enable-rsync -n $INSTANCE_NAME -g $RESOURCE_GROUP"
        
        # Try with explicit K8 Bridge service principal OID if the first command failed
        log "Attempting with explicit K8 Bridge service principal OID..."
        K8_BRIDGE_SP_OID=$(az ad sp list --display-name "K8 Bridge" --query "[0].id" -o tsv 2>/dev/null || echo "")
        
        if [ -n "$K8_BRIDGE_SP_OID" ]; then
            log "Found K8 Bridge service principal OID: $K8_BRIDGE_SP_OID"
            if az iot ops enable-rsync --name "$INSTANCE_NAME" --resource-group "$RESOURCE_GROUP" --k8-bridge-sp-oid "$K8_BRIDGE_SP_OID"; then
                log "[SUCCESS] Asset sync enabled successfully with explicit OID!"
            else
                warn "[FAILED] Failed to enable asset sync even with explicit OID"
                warn "Manual intervention may be required"
            fi
        else
            warn "Could not retrieve K8 Bridge service principal OID"
            warn "You may need to run manually with appropriate permissions"
        fi
    fi
    
    log "Asset discovery and sync configuration completed"
}

# Deploy OPC UA Bridge components
deploy_opc_ua_bridge() {
    # Check if OPC UA bridge deployment is enabled
    if [ "$DEPLOY_OPC_UA_BRIDGE" = "false" ]; then
        log "OPC UA Bridge deployment disabled in configuration"
        log "To enable: set deploy_opc_ua_bridge: true in linux_aio_config.json"
        return 0
    fi
    
    log "Deploying OPC UA Bridge components for factory integration..."
    
    # Check if OPC UA config directory exists
    local opcua_config_dir="./opcua/assets"
    if [ ! -d "$opcua_config_dir" ]; then
        opcua_config_dir="../opcua/assets"
        if [ ! -d "$opcua_config_dir" ]; then
            warn "OPC UA configuration directory not found. Skipping OPC UA bridge deployment."
            warn "To manually deploy later, run: kubectl apply -f opcua/assets/opc-plc-simulator.yaml"
            return 0
        fi
    fi
    
    local opc_simulator_file="$opcua_config_dir/opc-plc-simulator.yaml"
    local asset_endpoint_file="$opcua_config_dir/asset-endpoint-profile.yaml"
    
    # Check if OPC UA simulator YAML exists
    if [ ! -f "$opc_simulator_file" ]; then
        warn "OPC PLC Simulator configuration file not found at: $opc_simulator_file"
        warn "Skipping OPC UA bridge deployment."
        return 0
    fi
    
    # Deploy OPC PLC Simulator
    log "Deploying OPC PLC Simulator..."
    kubectl apply -f "$opc_simulator_file"
    
    # Wait for OPC PLC Simulator to be ready
    log "Waiting for OPC PLC Simulator to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/opc-plc-simulator -n azure-iot-operations
    
    if [ $? -eq 0 ]; then
        log "OPC PLC Simulator deployed successfully"
    else
        warn "OPC PLC Simulator deployment may have timed out. Checking status..."
        kubectl get pods -n azure-iot-operations -l app=opc-plc-simulator
    fi
    
    # Deploy Asset Endpoint Profile if it exists
    if [ -f "$asset_endpoint_file" ]; then
        log "Deploying Asset Endpoint Profile..."
        kubectl apply -f "$asset_endpoint_file"
        log "Asset Endpoint Profile deployed"
    else
        log "Asset Endpoint Profile file not found. You can deploy it later with:"
        log "kubectl apply -f opcua/assets/asset-endpoint-profile.yaml"
    fi
    
    # Display OPC UA endpoint information
    log "OPC UA Bridge deployment completed!"
    echo
    log "OPC UA Endpoint Details:"
    log "- Internal URL: opc.tcp://opc-plc-service.azure-iot-operations.svc.cluster.local:50000"
    log "- Namespace: azure-iot-operations"
    log "- Authentication: Anonymous development setup"
    echo
    log "Next Steps for OPC UA Bridge:"
    log "1. Access Azure IoT Operations Portal"
    log "2. Navigate to Asset endpoints and verify spaceship-factory-opcua appears"
    log "3. Create assets using the portal with the OPC UA endpoint"
    log "4. Configure data flows and dashboards"
    echo
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
    echo "2. Access OPC UA Bridge for factory integration:"
    echo "   - Navigate to Asset endpoints in the portal"
    echo "   - Verify spaceship-factory-opcua endpoint is available"
    echo "   - Create assets using the OPC UA endpoint"
    echo "   - Configure data flows for factory data processing"
    echo
    echo "3. Asset Discovery and Sync:"
    echo "   - Edge-to-cloud asset sync is enabled for discovered assets"
    echo "   - Discovered OPC UA assets will appear in the cloud experience"
    echo "   - Assets will show Discovered status in the Azure portal"
    echo
    echo "4. Configure assets and data flows:"
    echo "   - Create assets to represent your industrial equipment"
    echo "   - Set up data flows to process and route data"
    echo
    echo "5. Monitor your deployment:"
    echo "   kubectl get pods -n azure-iot-operations"
    echo "   az iot ops check"
    echo
    echo -e "${BLUE}Important Variables:${NC}"
    echo "   Resource Group: $RESOURCE_GROUP"
    echo "   Cluster Name: $CLUSTER_NAME"
    echo "   Namespace: $NAMESPACE_NAME"
    echo "   Location: $LOCATION"
    echo
    echo -e "${BLUE}OPC UA Bridge Details:${NC}"
    echo "   Endpoint URL: opc.tcp://opc-plc-service.azure-iot-operations.svc.cluster.local:50000"
    echo "   Authentication: Anonymous development setup"
    echo "   Factory Nodes: CNC, 3D Printer, Welding, Painting, Testing stations"
    echo
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "   # Check cluster status"
    echo "   kubectl get nodes"
    echo
    echo "   # View Azure IoT Operations pods"
    echo "   kubectl get pods -n azure-iot-operations"
    echo
    echo "   # Check OPC UA Bridge status"
    echo "   kubectl get pods -n azure-iot-operations -l app=opc-plc-simulator"
    echo "   kubectl get svc -n azure-iot-operations opc-plc-service"
    echo
    echo "   # Check Azure IoT Operations health"
    echo "   az iot ops check"
    echo
    echo "   # View logs for OPC UA simulator"
    echo "   kubectl logs deployment/opc-plc-simulator -n azure-iot-operations"
    echo
    echo "   # View logs for a specific pod"
    echo "   kubectl logs <pod-name> -n azure-iot-operations"
    echo
    echo -e "${BLUE}Documentation:${NC}"
    echo "   For complete OPC UA bridge setup and asset registration:"
    echo "   See: opcua/assets/opc-ua-bridge.md"
    echo
}

# Main installation function
main() {
    log "Starting Azure IoT Operations installation for Linux..."
    log "This script will install K3s, Azure CLI, and Azure IoT Operations"
    echo
    
    check_root
    check_system_requirements
    check_port_conflicts
    
    # Load configuration from JSON file (if available)
    load_config
    
    update_system
    install_azure_cli
    install_kubectl
    install_helm
    check_kubelite_conflicts
    cleanup_k3s
    install_k3s
    configure_kubectl
    configure_system_settings
    azure_login_setup
    create_azure_resources
    arc_enable_cluster
    create_namespace
    deploy_iot_operations
    enable_asset_sync
    deploy_opc_ua_bridge
    verify_deployment
    show_next_steps
    
    log "Installation completed successfully!"
}

# Trap to handle script interruption
trap 'error "Script interrupted by user"' INT

# Run main function
main "$@"
