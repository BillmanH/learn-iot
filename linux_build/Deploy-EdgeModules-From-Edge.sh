#!/bin/bash

################################################################################
# Deploy-EdgeModules-From-Edge.sh
#
# Deploy edge modules directly on the Linux edge device
# Builds containers locally and deploys to K3s cluster
#
# Usage (run from linux_build directory):
#   cd linux_build
#   ./Deploy-EdgeModules-From-Edge.sh [OPTIONS]
#
# Options:
#   -m, --module <name>       Specific module to deploy (edgemqttsim, hello-flask, sputnik, wasm-quality-filter-python, demohistorian)
#   -f, --force               Force redeployment even if module is running
#   -s, --skip-build          Skip container build and push
#   -t, --tag <tag>           Image tag (default: latest)
#   -c, --config <path>       Path to linux_aio_config.json
#   -h, --help                Show this help message
#
# Examples:
#   ./Deploy-EdgeModules-From-Edge.sh
#   ./Deploy-EdgeModules-From-Edge.sh -m hello-flask -f
#   ./Deploy-EdgeModules-From-Edge.sh -m edgemqttsim --skip-build
################################################################################

set -e  # Exit on error
set -o pipefail  # Catch errors in pipes

# Script variables (assumes running from linux_build directory)
SCRIPT_DIR="$(pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IOTOPPS_DIR="$REPO_ROOT/iotopps"
LOG_FILE="$SCRIPT_DIR/deploy_edge_modules_$(date +%Y%m%d_%H%M%S).log"
START_TIME=$(date +%s)

# Default parameters
MODULE_NAME=""
FORCE_REDEPLOY=false
SKIP_BUILD=false
IMAGE_TAG="latest"
CONFIG_PATH=""
CONTAINER_REGISTRY=""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

################################################################################
# Logging Functions
################################################################################

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${CYAN}[$timestamp] INFO: $1${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[$timestamp] SUCCESS: $1${NC}" | tee -a "$LOG_FILE"
}

log_warn() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[$timestamp] WARNING: $1${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[$timestamp] ERROR: $1${NC}" | tee -a "$LOG_FILE"
}

################################################################################
# Help Function
################################################################################

show_help() {
    cat << EOF
Deploy Edge Modules - Linux Native Build and Deploy
 (run from linux_build directory):
  cd linux_build
 
Usage: ./Deploy-EdgeModules-From-Edge.sh [OPTIONS]

Options:
  -m, --module <name>       Specific module to deploy
                            (edgemqttsim, hello-flask, sputnik, 
                             wasm-quality-filter-python, demohistorian)
  -f, --force               Force redeployment even if module is running
  -s, --skip-build          Skip container build and push
  -t, --tag <tag>           Image tag (default: latest)
  -c, --config <path>       Path to linux_aio_config.json
  -h, --help                Show this help message
cd linux_build
  ./Deploy-EdgeModules-From-Edge.sh

  # Deploy specific module with force redeploy
  ./Deploy-EdgeModules-From-Edge.sh -m hello-flask -f

  # Skip build and deploy only (assumes images exist)
  ./Deploy-EdgeModules-From-Edge.sh -m edgemqttsim --skip-build

  # Use custom config file
  ./Deploy-EdgeModules-From-Edge.sh -c edge_configs/linux_aio_im --skip-build

  # Use custom config file
  ./Deploy-EdgeModules-From-Edge.sh -c /path/to/config.json

EOF
}

################################################################################
# Parse Arguments
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--module)
                MODULE_NAME="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_REDEPLOY=true
                shift
                ;;
            -s|--skip-build)
                SKIP_BUILD=true
                shift
                ;;
            -t|--tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            -c|--config)
                CONFIG_PATH="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

################################################################################
# Configuration Functions
################################################################################

find_config_file() {
    log_info "Searching for linux_aio_config.json..." >&2
    
    local search_paths=(
        "$CONFIG_PATH"
        "linux_aio_config.json"
        "edge_configs/linux_aio_config.json"
    )
    
    for path in "${search_paths[@]}"; do
        if [[ -n "$path" ]] && [[ -f "$path" ]]; then
            log_info "Checking: $path" >&2
            log_success "Found configuration at: $path" >&2
            echo "$path"
            return 0
        fi
    done
    
    log_error "Configuration file linux_aio_config.json not found in current directory" >&2
    log_info "Make sure you're running this from the linux_build directory and the config file exists" >&2
    return 1
}

load_configuration() {
    local config_file="$1"
    
    # Get absolute path for clarity (avoid command substitution issues)
    local abs_config_path=""
    if [[ "$config_file" = /* ]]; then
        # Already absolute path
        abs_config_path="$config_file"
    else
        # Make it absolute
        abs_config_path="$(pwd)/$config_file"
    fi
    
    log_info "Loading configuration from: $config_file"
    log_info "Absolute path: $abs_config_path"
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Install with: sudo apt-get install jq"
        return 1
    fi
    
    # Check if file exists and is readable
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi
    
    if [[ ! -r "$config_file" ]]; then
        log_error "Cannot read configuration file: $config_file"
        log_info "Check file permissions: ls -l $config_file"
        return 1
    fi
    
    # Load container registry if specified
    CONTAINER_REGISTRY=$(jq -r '.azure.container_registry // empty' "$config_file" 2>&1)
    local jq_exit_code=$?
    
    if [[ $jq_exit_code -ne 0 ]]; then
        log_error "Failed to parse JSON from: $config_file"
        log_error "jq output: $CONTAINER_REGISTRY"
        return 1
    fi
    
    if [[ -n "$CONTAINER_REGISTRY" ]]; then
        log_info "Container registry: $CONTAINER_REGISTRY"
    else
        log_warn "No container_registry specified in config"
    fi
    
    # Show modules configuration
    echo ""
    echo "Modules Configuration:"
    
    local modules=$(jq -r '.modules // {} | to_entries[] | "\(.key)=\(.value)"' "$config_file" 2>/dev/null)
    if [[ -z "$modules" ]]; then
        echo "  (No modules configured)"
    else
        while IFS= read -r line; do
            local module_name="${line%=*}"
            local enabled="${line#*=}"
            if [[ "$enabled" == "true" ]]; then
                echo -e "  ${GREEN}$module_name: ENABLED${NC}"
            else
                echo "  $module_name: disabled"
            fi
        done <<< "$modules"
    fi
    echo ""
}

get_modules_to_deploy() {
    local config_file="$1"
    
    if [[ -n "$MODULE_NAME" ]]; then
        log_info "Deploying specific module: $MODULE_NAME" >&2
        echo "$MODULE_NAME"
        return 0
    fi
    
    # Get enabled modules from config
    local modules=$(jq -r '.modules // {} | to_entries[] | select(.value == true) | .key' "$config_file")
    
    if [[ -z "$modules" ]]; then
        log_warn "No modules enabled in configuration" >&2
        return 1
    fi
    
    log_info "Modules to deploy: $(echo $modules | tr '\n' ' ')" >&2
    echo "$modules"
}

################################################################################
# Validation Functions
################################################################################

# Detect available container build tool
CONTAINER_TOOL=""

detect_container_tool() {
    # Priority: docker > nerdctl > buildah
    if command -v docker &> /dev/null && docker ps &> /dev/null 2>&1; then
        CONTAINER_TOOL="docker"
        log_success "Using Docker for container builds"
        return 0
    elif command -v nerdctl &> /dev/null; then
        CONTAINER_TOOL="nerdctl"
        log_success "Using nerdctl (containerd) for container builds"
        return 0
    elif command -v buildah &> /dev/null; then
        CONTAINER_TOOL="buildah"
        log_success "Using buildah for container builds"
        return 0
    else
        log_error "No container build tool found (docker, nerdctl, or buildah)"
        echo ""
        echo "============================================================"
        echo "CONTAINER TOOL NOT FOUND"
        echo "============================================================"
        echo "K3s uses containerd, so you can install nerdctl:"
        echo ""
        echo "  # Quick install (recommended):"
        echo "  wget https://github.com/containerd/nerdctl/releases/download/v1.7.2/nerdctl-1.7.2-linux-amd64.tar.gz"
        echo "  sudo tar Cxzvvf /usr/local/bin nerdctl-1.7.2-linux-amd64.tar.gz"
        echo ""
        echo "  # Or use buildah:"
        echo "  sudo apt-get update && sudo apt-get install -y buildah"
        echo ""
        echo "  # Or install Docker:"
        echo "  curl -fsSL https://get.docker.com | sh"
        echo "============================================================"
        echo ""
        return 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        return 1
    fi
    log_success "kubectl found: $(kubectl version --client --short 2>/dev/null | head -1)"
    
    # Check for container build tool (only if not skipping build)
    if [[ "$SKIP_BUILD" == false ]]; then
        if ! detect_container_tool; then
            return 1
        fi
    fi
    
    # Check iotopps directory
    if [[ ! -d "$IOTOPPS_DIR" ]]; then
        log_error "iotopps directory not found: $IOTOPPS_DIR"
        echo ""
        echo "============================================================"
        echo "ERROR: iotopps directory not found"
        echo "============================================================"
        echo "This script must be run from the linux_build directory."
        echo ""
        echo "Expected directory structure:"
        echo "  learn-iot/"
        echo "    ├── linux_build/          ← Run script from here"
        echo "    │   ├── Deploy-EdgeModules-From-Edge.sh"
        echo "    │   └── linux_aio_config.json"
        echo "    └── iotopps/              ← Modules directory"
        echo "        ├── edgemqttsim/"
        echo "        ├── hello-flask/"
        echo "        └── ..."
        echo ""
        echo "To fix: cd ~/learn-iot/linux_build"
        echo "============================================================"
        echo ""
        return 1
    fi
    log_success "iotopps directory found: $IOTOPPS_DIR"
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_info "Ensure K3s is running: sudo systemctl status k3s"
        return 1
    fi
    log_success "Connected to Kubernetes cluster"
}

check_module_exists() {
    local module="$1"
    local module_path="$IOTOPPS_DIR/$module"
    local deployment_path="$module_path/deployment.yaml"
    
    if [[ ! -d "$module_path" ]]; then
        log_error "Module directory not found: $module_path"
        return 1
    fi
    
    if [[ ! -f "$deployment_path" ]]; then
        log_error "deployment.yaml not found: $deployment_path"
        return 1
    fi
    
    return 0
}

check_module_deployed() {
    local module="$1"
    
    log_info "Checking if $module is already deployed..."
    
    if kubectl get deployment -n default -l app="$module" &> /dev/null; then
        local count=$(kubectl get deployment -n default -l app="$module" --no-headers 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            log_info "$module deployment exists"
            return 0
        fi
    fi
    
    log_info "$module is not currently deployed"
    return 1
}

################################################################################
# Build and Push Functions
################################################################################

build_container_with_tool() {
    local tool="$1"
    local image_name="$2"
    local module_path="$3"
    
    case "$tool" in
        docker)
            docker build -t "$image_name" "$module_path" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
            ;;
        nerdctl)
            # nerdctl needs namespace specification for K3s
            sudo nerdctl -n k8s.io build -t "$image_name" "$module_path" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
            ;;
        buildah)
            buildah bud -t "$image_name" "$module_path" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
            ;;
        *)
            log_error "Unknown container tool: $tool"
            return 1
            ;;
    esac
}

push_container_with_tool() {
    local tool="$1"
    local image_name="$2"
    
    case "$tool" in
        docker)
            docker push "$image_name" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
            ;;
        nerdctl)
            sudo nerdctl -n k8s.io push "$image_name" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
            ;;
        buildah)
            buildah push "$image_name" 2>&1 | tee -a "$LOG_FILE"
            return ${PIPESTATUS[0]}
            ;;
        *)
            log_error "Unknown container tool: $tool"
            return 1
            ;;
    esac
}

build_and_push_container() {
    local module="$1"
    local registry="$2"
    local tag="$3"
    
    echo ""
    echo "========================================"
    echo "Building and Pushing Container: $module"
    echo "========================================"
    
    local module_path="$IOTOPPS_DIR/$module"
    
    if [[ ! -f "$module_path/Dockerfile" ]]; then
        log_error "Dockerfile not found for module: $module"
        return 1
    fi
    
    local image_name="$registry/$module:$tag"
    log_info "Building container image with $CONTAINER_TOOL..."
    log_info "Image: $image_name"
    log_info "Context: $module_path"
    
    # Build the image
    if ! build_container_with_tool "$CONTAINER_TOOL" "$image_name" "$module_path"; then
        log_error "Container build failed for $module with $CONTAINER_TOOL"
        
        if [[ "$CONTAINER_TOOL" == "nerdctl" ]]; then
            log_info "Note: nerdctl uses sudo to access containerd runtime"
        fi
        
        return 1
    fi
    
    log_success "Container built successfully"
    
    # Push the image
    log_info "Pushing image to registry: $registry"
    
    if ! push_container_with_tool "$CONTAINER_TOOL" "$image_name"; then
        log_error "Container push failed for $module"
        
        case "$CONTAINER_TOOL" in
            docker)
                log_warn "If registry requires authentication, run: docker login"
                ;;
            nerdctl)
                log_warn "If registry requires authentication, run: sudo nerdctl login"
                ;;
            buildah)
                log_warn "If registry requires authentication, run: buildah login"
                ;;
        esac
        
        return 1
    fi
    
    log_success "Container pushed successfully: $image_name"
}

################################################################################
# Deployment Functions
################################################################################

update_deployment_registry() {
    local deployment_path="$1"
    local module="$2"
    
    # Read deployment file
    local deployment_content=$(cat "$deployment_path")
    
    # Check if deployment contains registry placeholders
    if echo "$deployment_content" | grep -q '<YOUR_REGISTRY>'; then
        if [[ -z "$CONTAINER_REGISTRY" ]]; then
            log_error "Deployment file for '$module' contains <YOUR_REGISTRY> placeholder but no container_registry is configured"
            echo ""
            echo "============================================================"
            echo "CONFIGURATION ERROR: Container Registry Not Set"
            echo "============================================================"
            echo "Add 'container_registry' to azure section in linux_aio_config.json"
            echo ""
            echo 'Example:'
            echo '  "azure": {'
            echo '    "container_registry": "your-dockerhub-username"'
            echo '  }'
            echo "============================================================"
            return 1
        fi
        
        # Replace placeholder with actual registry
        deployment_content=$(echo "$deployment_content" | sed "s|<YOUR_REGISTRY>|$CONTAINER_REGISTRY|g")
    fi
    
    # Update namespace to 'default' instead of 'azure-iot-operations'
    deployment_content=$(echo "$deployment_content" | sed 's|namespace: azure-iot-operations|namespace: default|g')
    
    # Create temp file with updated content
    local temp_file="/tmp/${module}-deployment-$(date +%s).yaml"
    echo "$deployment_content" > "$temp_file"
    
    log_info "Created temporary deployment file: $temp_file"
    echo "$temp_file"
}

ensure_service_account() {
    local sa_name="${1:-mqtt-client}"
    local namespace="${2:-default}"
    
    log_info "Checking if service account '$sa_name' exists in namespace '$namespace'..."
    
    if kubectl get serviceaccount "$sa_name" -n "$namespace" &> /dev/null; then
        log_success "Service account '$sa_name' already exists"
        return 0
    fi
    
    log_info "Creating service account '$sa_name' in namespace '$namespace'..."
    if kubectl create serviceaccount "$sa_name" -n "$namespace" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Service account '$sa_name' created successfully"
        return 0
    else
        log_error "Failed to create service account '$sa_name'"
        return 1
    fi
}

deploy_module() {
    local module="$1"
    
    echo ""
    echo "========================================"
    echo "Deploying Module: $module"
    echo "========================================"
    
    # Check if module exists
    if ! check_module_exists "$module"; then
        return 1
    fi
    
    local module_path="$IOTOPPS_DIR/$module"
    local deployment_path="$module_path/deployment.yaml"
    
    # Check if already deployed
    if check_module_deployed "$module"; then
        if [[ "$FORCE_REDEPLOY" == false ]]; then
            log_warn "$module is already deployed. Use -f/--force to redeploy."
            return 0
        fi
        
        log_info "Force redeployment requested, deleting existing deployment..."
        kubectl delete deployment -n default -l app="$module" &> /dev/null || true
        sleep 3
    fi
    
    # Update deployment file with container registry if configured
    local final_deployment_path="$deployment_path"
    
    if [[ -n "$CONTAINER_REGISTRY" ]] || grep -q '<YOUR_REGISTRY>' "$deployment_path"; then
        final_deployment_path=$(update_deployment_registry "$deployment_path" "$module")
        if [[ $? -ne 0 ]]; then
            return 1
        fi
    fi
    
    # Deploy using kubectl
    log_info "Applying deployment.yaml for $module..."
    log_info "Path: $final_deployment_path"
    
    if ! kubectl apply -f "$final_deployment_path" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to deploy $module"
        
        # Clean up temp file if created
        if [[ "$final_deployment_path" != "$deployment_path" ]]; then
            rm -f "$final_deployment_path"
        fi
        
        return 1
    fi
    
    # Clean up temp file if created
    if [[ "$final_deployment_path" != "$deployment_path" ]]; then
        rm -f "$final_deployment_path"
    fi
    
    log_success "$module deployment applied successfully"
    
    # Wait for pod to be ready
    log_info "Waiting for pod to be ready (timeout: 60s)..."
    local timeout=60
    local elapsed=0
    local ready=false
    
    while [[ $elapsed -lt $timeout ]]; do
        local pod_status=$(kubectl get pods -n default -l app="$module" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        
        if [[ "$pod_status" == "Running" ]]; then
            log_success "$module pod is running"
            ready=true
            break
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    
    if [[ "$ready" == false ]]; then
        log_warn "$module pod did not become ready within timeout"
        log_info "Check status with: kubectl get pods -n default -l app=$module"
    fi
    
    # Show pod status
    log_info "Current pod status:"
    kubectl get pods -n default -l app="$module"
    
    return 0
}

show_deployment_status() {
    echo ""
    echo "========================================"
    echo "Deployment Status"
    echo "========================================"
    
    log_info "All deployments in default namespace:"
    kubectl get deployments -n default
    
    echo ""
    echo "Pods:"
    kubectl get pods -n default
    
    echo ""
    echo "Services:"
    kubectl get services -n default
}

show_summary() {
    local successful=$1
    local failed=$2
    local total=$3
    
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local minutes=$(echo "scale=2; $duration / 60" | bc)
    
    echo ""
    echo "============================================================================"
    echo "Edge Module Deployment Summary"
    echo "============================================================================"
    echo ""
    echo "Results:"
    echo "  Total modules: $total"
    echo -e "  ${GREEN}Successful: $successful${NC}"
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}Failed: $failed${NC}"
    fi
    
    echo ""
    echo "Deployment completed in $minutes minutes"
    echo "Log file: $LOG_FILE"
    
    echo ""
    echo "Next Steps:"
    echo "1. Check pod logs:"
    echo "   kubectl logs -n default -l app=<module-name>"
    echo ""
    echo "2. Monitor module status:"
    echo "   kubectl get pods -n default -w"
    echo ""
    echo "3. View module output (for MQTT modules):"
    echo "   kubectl logs -n default -l app=edgemqttsim -f"
    echo ""
}

################################################################################
# Main Function
################################################################################

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    echo "============================================================================"
    echo "Azure IoT Operations - Edge Module Deployment (Linux Native)"
    echo "============================================================================"
    echo "Log file: $LOG_FILE"
    echo "Started: $(date '+%m/%d/%Y %H:%M:%S')"
    echo ""
    echo "NOTE: Building and deploying directly on edge device"
    echo ""
    
    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    echo ""
    
    # Find and load configuration
    config_file=$(find_config_file)
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    load_configuration "$config_file"
    
    # Get modules to deploy
    modules_to_deploy=$(get_modules_to_deploy "$config_file")
    if [[ $? -ne 0 ]] || [[ -z "$modules_to_deploy" ]]; then
        log_warn "No modules to deploy"
        echo "Update linux_aio_config.json modules section to enable modules"
        exit 0
    fi
    
    # Build and push containers
    if [[ "$SKIP_BUILD" == false ]] && [[ -n "$CONTAINER_REGISTRY" ]]; then
        echo ""
        echo "========================================"
        echo "Building and Pushing Containers"
        echo "========================================"
        
        while IFS= read -r module; do
            if ! build_and_push_container "$module" "$CONTAINER_REGISTRY" "$IMAGE_TAG"; then
                log_error "Failed to build/push $module"
                exit 1
            fi
        done <<< "$modules_to_deploy"
    elif [[ -z "$CONTAINER_REGISTRY" ]]; then
        log_warn "No container registry configured - assuming images already exist"
    else
        log_info "Skipping container build (using existing images)"
    fi
    
    # Ensure mqtt-client service account exists
    echo ""
    echo "========================================"
    echo "Ensuring Service Account"
    echo "========================================"
    ensure_service_account "mqtt-client" "default" || log_warn "Failed to create service account"
    
    # Deploy each module
    local successful=0
    local failed=0
    local total=0
    
    while IFS= read -r module; do
        total=$((total + 1))
        if deploy_module "$module"; then
            successful=$((successful + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$modules_to_deploy"
    
    # Show final status
    show_deployment_status
    
    # Show summary
    show_summary "$successful" "$failed" "$total"
    
    if [[ $failed -gt 0 ]]; then
        log_warn "Some modules failed to deploy. Check logs for details."
        exit 1
    fi
    
    log_success "All edge modules deployed successfully!"
}

# Execute main function
main "$@"
