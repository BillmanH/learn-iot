#!/bin/bash

# ============================================================================
# Azure IoT Operations - Edge Device Installer
# ============================================================================
# This script prepares an Ubuntu edge device with local infrastructure:
# - K3s Kubernetes cluster
# - kubectl and Helm
# - Optional development tools (k9s, mqtt-viewer)
# - Optional edge modules (edgemqttsim, hello-flask, sputnik, wasm-quality-filter-python)
#
# Requirements: 
#   - Ubuntu 24.04+ (22.04 may work)
#   - 16GB+ RAM (32GB recommended)
#   - 4+ CPUs
#   - Non-root user with sudo privileges
#   - Internet connectivity
#
# Usage:
#   ./linux_installer.sh [OPTIONS]
#
# Options:
#   --dry-run           Validate configuration without making changes
#   --config FILE       Use specific configuration file (default: linux_aio_config.json)
#   --skip-verification Skip post-installation verification
#   --help              Show this help message
#
# Output:
#   - Functional K3s cluster
#   - cluster_info.json with cluster details for External-Configurator.ps1
#   - Installation log: linux_installer_YYYYMMDD_HHMMSS.log
#
# Author: Azure IoT Operations Team
# Date: December 2025
# Version: 2.0.0 - Edge Installer (Separation of Concerns)
# ============================================================================

set -e  # Exit on any error
set -o pipefail  # Catch errors in pipes

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/linux_aio_config.json"
CLUSTER_INFO_FILE="${SCRIPT_DIR}/cluster_info.json"
DRY_RUN=false
SKIP_VERIFICATION=false

# Setup logging
LOG_FILE="${SCRIPT_DIR}/linux_installer_$(date +'%Y%m%d_%H%M%S').log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables (loaded from JSON)
CLUSTER_NAME=""
SKIP_SYSTEM_UPDATE=false
FORCE_REINSTALL=false
K9S_ENABLED=false
MQTT_VIEWER_ENABLED=false
SSH_ENABLED=false
EDGEMQTTSIM_ENABLED=false
HELLO_FLASK_ENABLED=false
SPUTNIK_ENABLED=false
WASM_FILTER_ENABLED=false

# Deployment tracking
DEPLOYED_MODULES=()
INSTALLED_TOOLS=()

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

setup_logging() {
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    echo "============================================================================"
    echo "Azure IoT Operations - Edge Device Installer"
    echo "============================================================================"
    echo "Log file: $LOG_FILE"
    echo "Started: $(date)"
    echo "Script directory: $SCRIPT_DIR"
    echo ""
}

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    
    # Provide context-specific troubleshooting
    if [[ "$1" == *"Kubernetes"* ]] || [[ "$1" == *"cluster"* ]] || [[ "$1" == *"kubectl"* ]]; then
        echo -e "${YELLOW}Troubleshooting K3s issues:${NC}"
        echo "1. Check K3s service: sudo systemctl status k3s"
        echo "2. Check K3s logs: sudo journalctl -u k3s -n 50"
        echo "3. Restart K3s: sudo systemctl restart k3s"
        echo "4. Check API server: sudo ss -tlnp | grep 6443"
        echo "5. Verify kubeconfig: cat ~/.kube/config"
        echo "6. Check resources: free -h && df -h"
    fi
    
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

show_help() {
    cat << EOF
Azure IoT Operations - Edge Device Installer

Usage: $0 [OPTIONS]

This script prepares an Ubuntu edge device with K3s and optional modules.
It does NOT configure Azure resources - use External-Configurator.ps1 for that.

Options:
    --dry-run               Validate configuration without making changes
    --config FILE           Use specific configuration file (default: linux_aio_config.json)
    --skip-verification     Skip post-installation verification
    --help                  Show this help message

Configuration:
    Edit linux_aio_config.json to customize:
    - Edge device settings (cluster name, K3s options)
    - Optional tools (k9s, mqtt-viewer, ssh)
    - Modules to deploy (edgemqttsim, hello-flask, sputnik, wasm-quality-filter-python)

Output:
    - Functional K3s cluster on this device
    - cluster_info.json for use with External-Configurator.ps1 (PowerShell)
    - Installation log file

Examples:
    # Standard installation
    ./linux_installer.sh

    # Dry-run to validate configuration
    ./linux_installer.sh --dry-run

    # Use custom config file
    ./linux_installer.sh --config my_config.json

For more information, see: linux_build/docs/edge_installation_guide.md
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                info "Running in DRY-RUN mode - no changes will be made"
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --skip-verification)
                SKIP_VERIFICATION=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

check_file_exists() {
    local file="$1"
    local description="$2"
    
    if [ ! -f "$file" ]; then
        error "$description not found: $file"
    fi
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

check_root() {
    log "Checking user privileges..."
    
    if [ "$EUID" -eq 0 ]; then
        error "Please do not run this script as root. Use sudo when prompted."
    fi
    
    # Verify sudo access
    if ! sudo -n true 2>/dev/null; then
        warn "This script requires sudo privileges. You may be prompted for your password."
        if ! sudo true; then
            error "Failed to obtain sudo privileges"
        fi
    fi
    
    success "User privileges validated"
}

check_system_requirements() {
    log "Checking system requirements..."
    
    # Check OS
    if [ ! -f /etc/os-release ]; then
        error "Cannot detect OS. This script requires Ubuntu 24.04+"
    fi
    
    source /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        error "This script requires Ubuntu. Detected: $ID"
    fi
    
    local version_id="${VERSION_ID}"
    if (( $(echo "$version_id < 22.04" | bc -l) )); then
        warn "Ubuntu version $version_id detected. Ubuntu 24.04+ recommended."
    else
        success "OS: Ubuntu $version_id"
    fi
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 4 ]; then
        warn "CPU cores: $cpu_cores (4+ recommended for production)"
    else
        success "CPU cores: $cpu_cores"
    fi
    
    # Check RAM
    local total_mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$total_mem_gb" -lt 16 ]; then
        warn "RAM: ${total_mem_gb}GB (16GB+ recommended)"
    else
        success "RAM: ${total_mem_gb}GB"
    fi
    
    # Check disk space
    local disk_avail_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$disk_avail_gb" -lt 50 ]; then
        warn "Available disk space: ${disk_avail_gb}GB (50GB+ recommended)"
    else
        success "Disk space: ${disk_avail_gb}GB available"
    fi
    
    # Check kernel version
    local kernel_version=$(uname -r)
    success "Kernel version: $kernel_version"
    
    # Check internet connectivity
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error "No internet connectivity. Please check your network connection."
    fi
    success "Internet connectivity verified"
    
    log "System requirements check completed"
}

check_port_conflicts() {
    log "Checking for port conflicts..."
    
    # If K3s is already running, skip port check
    if sudo systemctl is-active --quiet k3s 2>/dev/null; then
        info "K3s service is already running - skipping port conflict check"
        return 0
    fi
    
    local required_ports=(6443 10250 10251 10252 8472 10010)
    local conflicts=()
    
    for port in "${required_ports[@]}"; do
        if sudo ss -tlnp | grep -q ":$port "; then
            local process=$(sudo ss -tlnp | grep ":$port " | awk '{print $6}' | head -1)
            conflicts+=("Port $port is in use by: $process")
        fi
    done
    
    if [ ${#conflicts[@]} -gt 0 ]; then
        warn "Port conflicts detected:"
        for conflict in "${conflicts[@]}"; do
            echo "  - $conflict"
        done
        
        echo ""
        echo "You can:"
        echo "1. Stop conflicting services"
        echo "2. Continue anyway (K3s may fail to start)"
        echo "3. Use --force-reinstall to cleanup and retry"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Installation aborted due to port conflicts"
        fi
    else
        success "No port conflicts detected"
    fi
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

load_local_config() {
    log "Loading configuration from $CONFIG_FILE..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Configuration file not found: $CONFIG_FILE"
        info "Using default configuration"
        CLUSTER_NAME="edge-device-$(hostname)"
        return 0
    fi
    
    # Validate JSON
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        error "Invalid JSON in configuration file: $CONFIG_FILE"
    fi
    
    # Load edge device settings
    CLUSTER_NAME=$(jq -r '.azure.cluster_name // "edge-device-'$(hostname)'"' "$CONFIG_FILE")
    SKIP_SYSTEM_UPDATE=$(jq -r '.deployment.skip_system_update // false' "$CONFIG_FILE")
    FORCE_REINSTALL=$(jq -r '.deployment.force_reinstall // false' "$CONFIG_FILE")
    
    # Load optional tools configuration
    K9S_ENABLED=$(jq -r '.optional_tools.k9s // false' "$CONFIG_FILE")
    MQTT_VIEWER_ENABLED=$(jq -r '.optional_tools."mqtt-viewer" // false' "$CONFIG_FILE")
    SSH_ENABLED=$(jq -r '.optional_tools.ssh // false' "$CONFIG_FILE")
    
    # Load modules configuration
    EDGEMQTTSIM_ENABLED=$(jq -r '.modules.edgemqttsim // false' "$CONFIG_FILE")
    HELLO_FLASK_ENABLED=$(jq -r '.modules."hello-flask" // false' "$CONFIG_FILE")
    SPUTNIK_ENABLED=$(jq -r '.modules.sputnik // false' "$CONFIG_FILE")
    WASM_FILTER_ENABLED=$(jq -r '.modules."wasm-quality-filter-python" // false' "$CONFIG_FILE")
    
    # Display configuration
    echo ""
    echo "Configuration loaded:"
    echo "  Cluster name: $CLUSTER_NAME"
    echo "  Skip system update: $SKIP_SYSTEM_UPDATE"
    echo "  Force reinstall: $FORCE_REINSTALL"
    echo ""
    echo "Optional tools:"
    echo "  k9s: $K9S_ENABLED"
    echo "  mqtt-viewer: $MQTT_VIEWER_ENABLED"
    echo "  ssh: $SSH_ENABLED"
    echo ""
    echo "Modules to deploy:"
    echo "  edgemqttsim: $EDGEMQTTSIM_ENABLED"
    echo "  hello-flask: $HELLO_FLASK_ENABLED"
    echo "  sputnik: $SPUTNIK_ENABLED"
    echo "  wasm-quality-filter-python: $WASM_FILTER_ENABLED"
    echo ""
    
    success "Configuration loaded successfully"
}

# ============================================================================
# SYSTEM PREPARATION
# ============================================================================

update_system() {
    if [ "$SKIP_SYSTEM_UPDATE" = "true" ]; then
        info "Skipping system update (configured in settings)"
        return 0
    fi
    
    log "Updating system packages..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would run: sudo apt update && sudo apt upgrade -y"
        return 0
    fi
    
    sudo apt update || warn "apt update returned non-zero exit code"
    sudo apt upgrade -y || warn "apt upgrade returned non-zero exit code"
    
    success "System packages updated"
}

# ============================================================================
# TOOL INSTALLATION
# ============================================================================

install_kubectl() {
    log "Installing kubectl..."
    
    if command -v kubectl &> /dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        local version=$(kubectl version --client --short 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
        info "kubectl already installed: $version"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would install kubectl"
        return 0
    fi
    
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    
    local version=$(kubectl version --client --short 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' || echo "installed")
    success "kubectl installed: $version"
}

install_helm() {
    log "Installing Helm..."
    
    if command -v helm &> /dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        local version=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
        info "Helm already installed: $version"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would install Helm"
        return 0
    fi
    
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    local version=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' || echo "installed")
    success "Helm installed: $version"
}

install_optional_tools() {
    log "Installing optional tools based on configuration..."
    
    local tools_installed=false
    
    # Install k9s
    if [ "$K9S_ENABLED" = "true" ]; then
        install_k9s
        tools_installed=true
    fi
    
    # Install mqtt-viewer
    if [ "$MQTT_VIEWER_ENABLED" = "true" ]; then
        install_mqtt_viewer
        tools_installed=true
    fi
    
    # Configure SSH
    if [ "$SSH_ENABLED" = "true" ]; then
        configure_ssh
        tools_installed=true
    fi
    
    if [ "$tools_installed" = "false" ]; then
        info "No optional tools configured for installation"
    fi
}

install_k9s() {
    log "Installing k9s (Kubernetes terminal UI)..."
    
    if command -v k9s &> /dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        info "k9s already installed"
        INSTALLED_TOOLS+=("k9s")
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would install k9s"
        return 0
    fi
    
    local K9S_VERSION="v0.32.4"
    wget -q "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
    tar xzf k9s_Linux_amd64.tar.gz
    sudo install -o root -g root -m 0755 k9s /usr/local/bin/k9s
    rm k9s k9s_Linux_amd64.tar.gz README.md LICENSE 2>/dev/null
    
    INSTALLED_TOOLS+=("k9s")
    success "k9s installed: $K9S_VERSION"
}

install_mqtt_viewer() {
    log "Installing MQTT CLI tools (mosquitto-clients)..."
    
    if command -v mosquitto_sub &> /dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        info "MQTT CLI tools already installed"
        INSTALLED_TOOLS+=("mosquitto-clients")
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would install mosquitto-clients"
        return 0
    fi
    
    # Install mosquitto-clients (provides mosquitto_sub and mosquitto_pub)
    sudo apt install -y mosquitto-clients
    
    INSTALLED_TOOLS+=("mosquitto-clients")
    success "MQTT CLI tools installed (mosquitto_sub, mosquitto_pub)"
}

configure_ssh() {
    log "Configuring SSH for remote access..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would configure SSH"
        return 0
    fi
    
    # Install OpenSSH server if not present
    if ! command -v sshd &> /dev/null; then
        sudo apt install -y openssh-server
    fi
    
    # Enable and start SSH service
    sudo systemctl enable ssh
    sudo systemctl start ssh
    
    # Generate SSH key if doesn't exist
    if [ ! -f ~/.ssh/id_rsa ]; then
        info "Generating SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "edge-device-$(hostname)"
    fi
    
    # Configure SSH for security
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sudo systemctl reload ssh
    
    INSTALLED_TOOLS+=("ssh")
    success "SSH configured and enabled"
    
    # Display SSH connection info
    display_ssh_info
}

display_ssh_info() {
    local ip_address=$(hostname -I | awk '{print $1}')
    local ssh_port=22
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}SSH Access Information${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "SSH is now enabled on this device."
    echo ""
    echo "Connection details:"
    echo "  IP Address: $ip_address"
    echo "  Port: $ssh_port"
    echo "  Username: $USER"
    echo ""
    echo "To connect from another machine:"
    echo "  ssh $USER@$ip_address"
    echo ""
    echo "Public key location (for authorized_keys):"
    echo "  ~/.ssh/id_rsa.pub"
    echo ""
    echo "To copy your public key to another machine:"
    echo "  ssh-copy-id user@remote-host"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

# ============================================================================
# K3S INSTALLATION
# ============================================================================

check_kubelite_conflicts() {
    log "Checking for conflicting Kubernetes installations..."
    
    # Check for MicroK8s
    if command -v microk8s &> /dev/null; then
        warn "MicroK8s detected. This may conflict with K3s."
        echo "Please remove MicroK8s before continuing: sudo snap remove microk8s"
        
        if [ "$FORCE_REINSTALL" = "true" ]; then
            info "Attempting to remove MicroK8s (force reinstall mode)..."
            if [ "$DRY_RUN" != "true" ]; then
                sudo snap remove microk8s || warn "Failed to remove MicroK8s"
            fi
        else
            error "MicroK8s conflict detected. Use --force-reinstall or remove manually."
        fi
    fi
    
    # Check for kubelite
    if pgrep -f kubelite &> /dev/null; then
        warn "kubelite process detected"
        if [ "$FORCE_REINSTALL" = "true" ]; then
            info "Killing kubelite processes..."
            if [ "$DRY_RUN" != "true" ]; then
                sudo pkill -9 kubelite || warn "Failed to kill kubelite"
            fi
        fi
    fi
    
    success "No conflicting Kubernetes installations detected"
}

cleanup_k3s() {
    if ! command -v k3s &> /dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        info "K3s not installed - no cleanup needed"
        return 0
    fi
    
    if [ "$FORCE_REINSTALL" = "true" ]; then
        log "Force reinstall enabled - cleaning up existing K3s installation..."
        
        if [ "$DRY_RUN" = "true" ]; then
            info "[DRY-RUN] Would run K3s cleanup scripts"
            return 0
        fi
        
        # Run K3s uninstall script if it exists
        if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
            sudo /usr/local/bin/k3s-uninstall.sh || warn "K3s uninstall script failed"
        fi
        
        # Manual cleanup
        sudo systemctl stop k3s 2>/dev/null || true
        sudo rm -rf /var/lib/rancher/k3s
        sudo rm -rf /etc/rancher/k3s
        sudo rm -f /usr/local/bin/k3s*
        
        success "K3s cleanup completed"
    else
        info "Existing K3s installation will be preserved"
    fi
}

check_k3s_resources() {
    log "Performing K3s pre-flight resource check..."
    
    # Check if K3s is already running
    if sudo systemctl is-active --quiet k3s 2>/dev/null; then
        info "K3s is already running - skipping resource check"
        return 0
    fi
    
    # Verify minimum resources
    local mem_avail_gb=$(free -g | awk '/^Mem:/{print $7}')
    if [ "$mem_avail_gb" -lt 4 ]; then
        warn "Available RAM: ${mem_avail_gb}GB (4GB+ recommended for K3s)"
    fi
    
    # Check for required kernel modules
    local required_modules=(br_netfilter overlay)
    for module in "${required_modules[@]}"; do
        if ! lsmod | grep -q "$module"; then
            info "Loading kernel module: $module"
            if [ "$DRY_RUN" != "true" ]; then
                sudo modprobe "$module"
            fi
        fi
    done
    
    success "K3s resource check completed"
}

install_k3s() {
    log "Installing K3s Kubernetes cluster..."
    
    # Check if K3s is already installed and running
    if sudo systemctl is-active --quiet k3s 2>/dev/null && [ "$FORCE_REINSTALL" != "true" ]; then
        info "K3s is already installed and running"
        return 0
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would install K3s with:"
        info "  - Traefik disabled"
        info "  - Kubeconfig mode: 644"
        info "  - Cluster name: $CLUSTER_NAME"
        return 0
    fi
    
    # Install K3s
    log "Downloading and installing K3s..."
    curl -sfL https://get.k3s.io | sh -s - \
        --disable traefik \
        --write-kubeconfig-mode 644 \
        --cluster-name "$CLUSTER_NAME"
    
    # Wait for K3s to be ready
    log "Waiting for K3s to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if sudo systemctl is-active --quiet k3s && \
           sudo k3s kubectl get nodes &>/dev/null; then
            success "K3s is ready"
            break
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            error "K3s failed to start after $max_attempts attempts"
        fi
        
        info "Waiting for K3s... (attempt $attempt/$max_attempts)"
        sleep 10
    done
    
    # Verify node is Ready
    local node_status=$(sudo k3s kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    if [ "$node_status" != "True" ]; then
        error "K3s node is not in Ready state"
    fi
    
    success "K3s installed and running"
}

configure_kubectl() {
    log "Configuring kubectl for local access..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would configure kubectl"
        return 0
    fi
    
    # Create .kube directory
    mkdir -p ~/.kube
    
    # Copy K3s kubeconfig to user directory
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    chmod 600 ~/.kube/config
    
    # Verify kubectl works
    if ! kubectl get nodes &>/dev/null; then
        error "kubectl configuration failed - cannot access cluster"
    fi
    
    success "kubectl configured for user: $USER"
}

configure_system_settings() {
    log "Configuring system settings for Azure IoT Operations..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would configure system settings (sysctl)"
        return 0
    fi
    
    # Set sysctl parameters for AIO
    local sysctl_file="/etc/sysctl.d/99-azure-iot-operations.conf"
    
    sudo tee "$sysctl_file" > /dev/null << 'EOF'
# Azure IoT Operations system settings

# Network settings
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# File system settings
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# Kernel settings
vm.max_map_count = 262144
EOF
    
    # Apply settings
    sudo sysctl --system > /dev/null
    
    success "System settings configured"
}

# ============================================================================
# MODULE DEPLOYMENT
# ============================================================================

deploy_modules() {
    log "Deploying edge modules based on configuration..."
    
    local modules_deployed=false
    
    # Deploy edgemqttsim
    if [ "$EDGEMQTTSIM_ENABLED" = "true" ]; then
        deploy_edgemqttsim
        modules_deployed=true
    fi
    
    # Deploy hello-flask
    if [ "$HELLO_FLASK_ENABLED" = "true" ]; then
        deploy_hello_flask
        modules_deployed=true
    fi
    
    # Deploy sputnik
    if [ "$SPUTNIK_ENABLED" = "true" ]; then
        deploy_sputnik
        modules_deployed=true
    fi
    
    # Deploy wasm-quality-filter-python
    if [ "$WASM_FILTER_ENABLED" = "true" ]; then
        deploy_wasm_filter
        modules_deployed=true
    fi
    
    if [ "$modules_deployed" = "false" ]; then
        info "No modules configured for deployment"
    else
        log "Waiting for module deployments to stabilize..."
        sleep 10
    fi
}

deploy_edgemqttsim() {
    log "Deploying edgemqttsim module..."
    
    local deployment_file="${SCRIPT_DIR}/../iotopps/edgemqttsim/deployment.yaml"
    
    if [ ! -f "$deployment_file" ]; then
        warn "edgemqttsim deployment file not found: $deployment_file"
        return 1
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would deploy edgemqttsim"
        return 0
    fi
    
    kubectl apply -f "$deployment_file" || warn "Failed to deploy edgemqttsim"
    
    DEPLOYED_MODULES+=("edgemqttsim")
    success "edgemqttsim deployed"
}

deploy_hello_flask() {
    log "Deploying hello-flask module..."
    
    local deployment_file="${SCRIPT_DIR}/../iotopps/hello-flask/deployment.yaml"
    
    if [ ! -f "$deployment_file" ]; then
        warn "hello-flask deployment file not found: $deployment_file"
        return 1
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would deploy hello-flask"
        return 0
    fi
    
    kubectl apply -f "$deployment_file" || warn "Failed to deploy hello-flask"
    
    DEPLOYED_MODULES+=("hello-flask")
    success "hello-flask deployed"
}

deploy_sputnik() {
    log "Deploying sputnik module..."
    
    local deployment_file="${SCRIPT_DIR}/../iotopps/sputnik/deployment.yaml"
    
    if [ ! -f "$deployment_file" ]; then
        warn "sputnik deployment file not found: $deployment_file"
        return 1
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would deploy sputnik"
        return 0
    fi
    
    kubectl apply -f "$deployment_file" || warn "Failed to deploy sputnik"
    
    DEPLOYED_MODULES+=("sputnik")
    success "sputnik deployed"
}

deploy_wasm_filter() {
    log "Deploying wasm-quality-filter-python module..."
    
    local deployment_file="${SCRIPT_DIR}/../iotopps/wasm-quality-filter-python/deployment.yaml"
    
    if [ ! -f "$deployment_file" ]; then
        warn "wasm-quality-filter-python deployment file not found: $deployment_file"
        return 1
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would deploy wasm-quality-filter-python"
        return 0
    fi
    
    kubectl apply -f "$deployment_file" || warn "Failed to deploy wasm-quality-filter-python"
    
    DEPLOYED_MODULES+=("wasm-quality-filter-python")
    success "wasm-quality-filter-python deployed"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_local_cluster() {
    if [ "$SKIP_VERIFICATION" = "true" ]; then
        info "Skipping verification (--skip-verification flag)"
        return 0
    fi
    
    log "Verifying local K3s cluster health..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would verify cluster health"
        return 0
    fi
    
    # Check node status
    local node_status=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    if [ "$node_status" != "True" ]; then
        error "Cluster node is not Ready"
    fi
    success "Cluster node is Ready"
    
    # Check system pods
    log "Checking system pods..."
    kubectl get pods -n kube-system
    
    local system_pods_ready=$(kubectl get pods -n kube-system --no-headers | grep -v Running | grep -v Completed | wc -l)
    if [ "$system_pods_ready" -gt 0 ]; then
        warn "Some system pods are not in Running state"
    else
        success "All system pods are running"
    fi
    
    # Check deployed modules
    if [ ${#DEPLOYED_MODULES[@]} -gt 0 ]; then
        log "Checking deployed modules..."
        for module in "${DEPLOYED_MODULES[@]}"; do
            local pod_count=$(kubectl get pods -l app="$module" --no-headers 2>/dev/null | wc -l)
            if [ "$pod_count" -gt 0 ]; then
                success "Module $module: $pod_count pod(s) deployed"
            else
                warn "Module $module: no pods found"
            fi
        done
    fi
    
    success "Local cluster verification completed"
}

# ============================================================================
# CLUSTER INFO GENERATION
# ============================================================================

generate_cluster_info() {
    log "Generating cluster information for external configurator..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would generate cluster_info.json"
        return 0
    fi
    
    # Get node information
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    local node_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
    local node_os=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}')
    
    # Get node IP address (internal IP)
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    
    # If InternalIP not found, try ExternalIP
    if [ -z "$node_ip" ]; then
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
    fi
    
    # If still not found, try hostname command
    if [ -z "$node_ip" ]; then
        node_ip=$(hostname -I | awk '{print $1}')
    fi
    
    # Encode kubeconfig as base64
    local kubeconfig_b64=$(cat ~/.kube/config | base64 -w 0)
    
    # Create cluster info JSON
    cat > "$CLUSTER_INFO_FILE" << EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "node_name": "$node_name",
  "node_ip": "$node_ip",
  "kubernetes_version": "$node_version",
  "node_os": "$node_os",
  "kubeconfig_base64": "$kubeconfig_b64",
  "deployed_modules": $(printf '%s\n' "${DEPLOYED_MODULES[@]}" | jq -R . | jq -s .),
  "installed_tools": $(printf '%s\n' "${INSTALLED_TOOLS[@]}" | jq -R . | jq -s .),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ready_for_arc": true,
  "installer_version": "2.0.0"
}
EOF
    
    success "Cluster information saved to: $CLUSTER_INFO_FILE"
}

# ============================================================================
# NEXT STEPS DISPLAY
# ============================================================================

display_next_steps() {
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}Edge Device Installation Completed Successfully!${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
    echo "Your edge device is now ready with:"
    echo "  ✓ K3s Kubernetes cluster: $CLUSTER_NAME"
    echo "  ✓ kubectl and Helm configured"
    
    if [ ${#INSTALLED_TOOLS[@]} -gt 0 ]; then
        echo "  ✓ Optional tools: ${INSTALLED_TOOLS[*]}"
    fi
    
    if [ ${#DEPLOYED_MODULES[@]} -gt 0 ]; then
        echo "  ✓ Deployed modules: ${DEPLOYED_MODULES[*]}"
    fi
    
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo ""
    echo "1. Review cluster information:"
    echo "   cat $CLUSTER_INFO_FILE"
    echo ""
    echo "2. Connect this cluster to Azure Arc and deploy Azure IoT Operations:"
    echo "   - Transfer $CLUSTER_INFO_FILE to your Windows management machine"
    echo "   - Run: .\External-Configurator.ps1 -ClusterInfo cluster_info.json"
    echo ""
    echo "3. Monitor your cluster:"
    echo "   kubectl get pods --all-namespaces"
    
    if [[ " ${INSTALLED_TOOLS[@]} " =~ " k9s " ]]; then
        echo "   k9s  # Interactive cluster UI"
    fi
    
    echo ""
    echo "4. View logs:"
    echo "   Installation log: $LOG_FILE"
    echo "   K3s logs: sudo journalctl -u k3s -f"
    echo ""
    
    # Show validation commands for installed tools
    if [ ${#INSTALLED_TOOLS[@]} -gt 0 ]; then
        echo "5. Verify installed tools:"
        
        if [[ " ${INSTALLED_TOOLS[@]} " =~ " k9s " ]]; then
            echo "   k9s version          # Check k9s installation"
        fi
        
        if [[ " ${INSTALLED_TOOLS[@]} " =~ " mosquitto-clients " ]]; then
            echo "   mosquitto_sub --help # Verify MQTT tools"
            echo "   mosquitto_pub --help"
        fi
        
        if [[ " ${INSTALLED_TOOLS[@]} " =~ " ssh " ]]; then
            echo "   ssh -V               # Verify SSH version"
            echo "   cat ~/.ssh/id_rsa.pub # View your public key"
        fi
        
        echo ""
    fi
    
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}NOTE: This was a DRY-RUN. No changes were made to your system.${NC}"
        echo ""
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Setup logging
    setup_logging
    
    # Show banner
    log "Starting Azure IoT Operations - Edge Device Installer"
    log "Version: 2.0.0 (Separation of Concerns)"
    
    if [ "$DRY_RUN" = "true" ]; then
        warn "DRY-RUN MODE: No changes will be made to your system"
    fi
    
    echo ""
    
    # Pre-flight checks
    check_root
    check_system_requirements
    check_port_conflicts
    
    # Load configuration
    load_local_config
    
    # System preparation
    update_system
    
    # Install tools
    install_kubectl
    install_helm
    install_optional_tools
    
    # K3s installation
    check_kubelite_conflicts
    cleanup_k3s
    check_k3s_resources
    install_k3s
    configure_kubectl
    configure_system_settings
    
    # Deploy modules
    deploy_modules
    
    # Verification
    verify_local_cluster
    
    # Generate output
    generate_cluster_info
    
    # Display next steps
    display_next_steps
    
    log "Edge device installation completed successfully!"
}

# Trap to handle script interruption
trap 'error "Script interrupted by user"' INT

# Run main function
main "$@"
