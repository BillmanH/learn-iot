#!/bin/bash

# ============================================================================
# Azure IoT Operations - Observability Installer
# ============================================================================
# Deploys full observability stack for an AIO cluster:
#   - Azure Monitor workspace (Managed Prometheus)
#   - Azure Managed Grafana
#   - Log Analytics workspace (Container Insights)
#   - OpenTelemetry Collector (Helm, in-cluster)
#   - Prometheus scrape ConfigMap
#   - AIO observability configuration upgrade
#   - Grafana dashboard import
#
# Requirements:
#   - Arc-enabled K3s cluster already deployed
#   - Azure CLI installed and authenticated (az login)
#   - kubectl and helm available
#   - jq installed (sudo apt-get install -y jq)
#   - aio_config.json present in ../config/
#
# Usage:
#   ./install_observability.sh [OPTIONS]
#
# Options:
#   --config FILE         Use specific config file (default: ../config/aio_config.json)
#   --workspace-name      Override Azure Monitor workspace name
#   --grafana-name        Override Grafana instance name
#   --logs-workspace-name Override Log Analytics workspace name
#   --instance-name       Override AIO instance name
#   --skip-azure          Skip Azure resource creation (only deploy in-cluster components)
#   --skip-dashboards     Skip Grafana dashboard import
#   --dry-run             Show what would be done without making changes
#   --help                Show this help message
#
# The script is idempotent - safe to run multiple times.
# Existing resources are skipped; changed resources are updated.
#
# Author: Azure IoT Operations Team
# Version: 1.0.0
# ============================================================================

set -o pipefail  # Catch errors in pipes

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../config"
CONFIG_FILE="${CONFIG_DIR}/aio_config.json"
LOG_FILE="${SCRIPT_DIR}/observability_install_$(date +'%Y%m%d_%H%M%S').log"

DRY_RUN=false
SKIP_AZURE=false
SKIP_DASHBOARDS=false

# Overridable resource names (derived from cluster name if not set)
ARG_WORKSPACE_NAME=""
ARG_GRAFANA_NAME=""
ARG_LOGS_WORKSPACE_NAME=""
ARG_INSTANCE_NAME=""

# Resolved config values
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
LOCATION=""
CLUSTER_NAME=""
INSTANCE_NAME=""
WORKSPACE_NAME=""
GRAFANA_NAME=""
LOGS_WORKSPACE_NAME=""

# OTel Collector values (match otel-collector-values.yaml)
OTEL_FULLNAME="aio-otel-collector"
OTEL_GRPC_PORT="4317"
OTEL_CHECK_INTERVAL="60"
OTEL_NAMESPACE="azure-iot-operations"
OTEL_IMAGE_TAG="0.143.0"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# LOGGING
# ============================================================================

setup_logging() {
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1

    echo "============================================================================"
    echo "Azure IoT Operations - Observability Installer"
    echo "============================================================================"
    echo "Log file: $LOG_FILE"
    echo "Started:  $(date)"
    echo ""
}

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')] INFO: $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARN: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] SUCCESS: $1${NC}"
}

section() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

step() {
    echo -e "${BLUE}  --> $1${NC}"
}

dry_run_cmd() {
    echo -e "${YELLOW}  [DRY-RUN] Would run: $*${NC}"
}

# Run a command, or print it in dry-run mode
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_cmd "$@"
    else
        "$@"
    fi
}

# ============================================================================
# HELP
# ============================================================================

show_help() {
    cat << EOF
Azure IoT Operations - Observability Installer

Usage: $0 [OPTIONS]

Deploys the full AIO observability stack (Azure Monitor, Grafana, OTel Collector,
Prometheus scrape config, and Grafana dashboards). Safe to run multiple times.

Options:
    --config FILE             Config file path (default: ../config/aio_config.json)
    --workspace-name NAME     Azure Monitor workspace name (default: <cluster>-metrics)
    --grafana-name NAME       Azure Managed Grafana name (default: <cluster>-grafana)
    --logs-workspace-name     Log Analytics workspace name (default: <cluster>-logs)
    --instance-name NAME      AIO instance name (auto-detected if not set)
    --skip-azure              Skip Azure resource creation; only deploy in-cluster
    --skip-dashboards         Skip Grafana dashboard import
    --dry-run                 Print commands without executing
    --help                    Show this help

Example:
    ./install_observability.sh
    ./install_observability.sh --skip-dashboards
    ./install_observability.sh --dry-run
EOF
    exit 0
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"; shift 2 ;;
            --workspace-name)
                ARG_WORKSPACE_NAME="$2"; shift 2 ;;
            --grafana-name)
                ARG_GRAFANA_NAME="$2"; shift 2 ;;
            --logs-workspace-name)
                ARG_LOGS_WORKSPACE_NAME="$2"; shift 2 ;;
            --instance-name)
                ARG_INSTANCE_NAME="$2"; shift 2 ;;
            --skip-azure)
                SKIP_AZURE=true; shift ;;
            --skip-dashboards)
                SKIP_DASHBOARDS=true; shift ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --help|-h)
                show_help ;;
            *)
                error "Unknown argument: $1. Use --help for usage." ;;
        esac
    done
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

check_prerequisites() {
    section "Checking Prerequisites"

    local missing=()

    step "Checking for jq..."
    if ! command -v jq &>/dev/null; then
        missing+=("jq (install with: sudo apt-get install -y jq)")
    else
        success "jq found: $(jq --version)"
    fi

    step "Checking for Azure CLI..."
    if ! command -v az &>/dev/null; then
        missing+=("azure-cli (see https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)")
    else
        success "az found: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
    fi

    step "Checking for kubectl..."
    if ! command -v kubectl &>/dev/null; then
        missing+=("kubectl (see https://kubernetes.io/docs/tasks/tools/)")
    else
        success "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
    fi

    step "Checking for helm..."
    if ! command -v helm &>/dev/null; then
        missing+=("helm (see https://helm.sh/docs/intro/install/)")
    else
        success "helm found: $(helm version --short)"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        error "Missing prerequisites:\n$(printf '  - %s\n' "${missing[@]}")"
    fi

    step "Checking config file: $CONFIG_FILE..."
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Config file not found: $CONFIG_FILE\nExpected aio_config.json in ${CONFIG_DIR}/"
    fi
    success "Config file found"

    if [[ "$SKIP_AZURE" != "true" ]]; then
        step "Checking Azure CLI login..."
        if ! az account show &>/dev/null; then
            error "Not logged in to Azure CLI. Run: az login"
        fi
        success "Azure CLI authenticated as: $(az account show --query user.name -o tsv)"
    fi

    step "Checking kubectl cluster access..."
    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    fi
    success "Cluster accessible: $(kubectl cluster-info 2>/dev/null | head -1)"
}

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================

load_config() {
    section "Loading Configuration"

    step "Reading $CONFIG_FILE..."

    SUBSCRIPTION_ID=$(jq -r '.azure.subscription_id // empty' "$CONFIG_FILE")
    RESOURCE_GROUP=$(jq -r '.azure.resource_group // empty' "$CONFIG_FILE")
    LOCATION=$(jq -r '.azure.location // empty' "$CONFIG_FILE")
    CLUSTER_NAME=$(jq -r '.azure.cluster_name // empty' "$CONFIG_FILE")

    # Validate required fields
    [[ -z "$SUBSCRIPTION_ID" ]] && error "Missing 'azure.subscription_id' in $CONFIG_FILE"
    [[ -z "$RESOURCE_GROUP" ]]  && error "Missing 'azure.resource_group' in $CONFIG_FILE"
    [[ -z "$CLUSTER_NAME" ]]    && error "Missing 'azure.cluster_name' in $CONFIG_FILE"

    # Location is required for resource creation; warn if missing
    if [[ -z "$LOCATION" && "$SKIP_AZURE" != "true" ]]; then
        warn "No 'azure.location' in config. Will attempt to read from existing resource group."
        LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
        [[ -z "$LOCATION" ]] && error "Could not determine location. Add 'location' to aio_config.json."
    fi

    # Derive resource names (allow CLI overrides)
    WORKSPACE_NAME="${ARG_WORKSPACE_NAME:-${CLUSTER_NAME}-metrics}"
    GRAFANA_NAME="${ARG_GRAFANA_NAME:-${CLUSTER_NAME}-grafana}"
    LOGS_WORKSPACE_NAME="${ARG_LOGS_WORKSPACE_NAME:-${CLUSTER_NAME}-logs}"

    # Instance name: use override, or auto-detect from cluster
    if [[ -n "$ARG_INSTANCE_NAME" ]]; then
        INSTANCE_NAME="$ARG_INSTANCE_NAME"
    fi

    log "Configuration loaded:"
    info "  Subscription:        $SUBSCRIPTION_ID"
    info "  Resource Group:      $RESOURCE_GROUP"
    info "  Location:            $LOCATION"
    info "  Cluster Name:        $CLUSTER_NAME"
    info "  Monitor Workspace:   $WORKSPACE_NAME"
    info "  Grafana Name:        $GRAFANA_NAME"
    info "  Logs Workspace:      $LOGS_WORKSPACE_NAME"
    info "  AIO Instance:        ${INSTANCE_NAME:-<auto-detect>}"
    info "  Skip Azure:          $SKIP_AZURE"
    info "  Skip Dashboards:     $SKIP_DASHBOARDS"
    info "  Dry Run:             $DRY_RUN"
}

# ============================================================================
# STEP 1: REGISTER PROVIDERS
# ============================================================================

register_providers() {
    section "Step 1/8: Registering Azure Resource Providers"

    step "Setting subscription to $SUBSCRIPTION_ID..."
    run_cmd az account set -s "$SUBSCRIPTION_ID"

    local providers=(
        "Microsoft.AlertsManagement"
        "Microsoft.Monitor"
        "Microsoft.Dashboard"
        "Microsoft.Insights"
        "Microsoft.OperationalInsights"
    )

    for provider in "${providers[@]}"; do
        local state
        state=$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
        if [[ "$state" == "Registered" ]]; then
            info "  Already registered: $provider"
        else
            step "Registering $provider (state: $state)..."
            run_cmd az provider register --namespace "$provider" --wait
            success "Registered: $provider"
        fi
    done

    success "All resource providers registered"
}

# ============================================================================
# STEP 2: INSTALL CLI EXTENSIONS
# ============================================================================

install_cli_extensions() {
    section "Step 2/8: Installing Azure CLI Extensions"

    local extensions=("k8s-extension" "amg")

    for ext in "${extensions[@]}"; do
        step "Checking extension: $ext..."
        if az extension show --name "$ext" &>/dev/null; then
            info "  Extension exists, checking for update: $ext"
            run_cmd az extension update --name "$ext" 2>/dev/null || true
        else
            step "Installing extension: $ext..."
            run_cmd az extension add --upgrade --name "$ext"
        fi
        success "Extension ready: $ext"
    done
}

# ============================================================================
# STEP 3: CREATE AZURE RESOURCES
# ============================================================================

create_azure_resources() {
    section "Step 3/8: Creating Azure Monitoring Resources"

    # -- Azure Monitor Workspace --
    step "Checking Azure Monitor workspace: $WORKSPACE_NAME..."
    local monitor_id
    monitor_id=$(az monitor account show \
        --name "$WORKSPACE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv 2>/dev/null || true)

    if [[ -n "$monitor_id" ]]; then
        info "  Azure Monitor workspace already exists: $WORKSPACE_NAME"
    else
        step "Creating Azure Monitor workspace: $WORKSPACE_NAME in $LOCATION..."
        if [[ "$DRY_RUN" == "true" ]]; then
            dry_run_cmd az monitor account create --name "$WORKSPACE_NAME" \
                --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --query id -o tsv
            monitor_id="<DRY_RUN_MONITOR_ID>"
        else
            monitor_id=$(az monitor account create \
                --name "$WORKSPACE_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --location "$LOCATION" \
                --query id -o tsv)
        fi
        success "Created Azure Monitor workspace: $WORKSPACE_NAME"
    fi
    info "  Azure Monitor workspace ID: $monitor_id"

    # -- Azure Managed Grafana --
    step "Checking Grafana instance: $GRAFANA_NAME..."
    local grafana_id
    grafana_id=$(az grafana show \
        --name "$GRAFANA_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv 2>/dev/null || true)

    if [[ -n "$grafana_id" ]]; then
        info "  Grafana instance already exists: $GRAFANA_NAME"
    else
        step "Creating Grafana instance: $GRAFANA_NAME (this may take several minutes)..."
        if [[ "$DRY_RUN" == "true" ]]; then
            dry_run_cmd az grafana create --name "$GRAFANA_NAME" \
                --resource-group "$RESOURCE_GROUP" --query id -o tsv
            grafana_id="<DRY_RUN_GRAFANA_ID>"
        else
            grafana_id=$(az grafana create \
                --name "$GRAFANA_NAME" \
                --resource-group "$RESOURCE_GROUP" \
                --query id -o tsv)
        fi
        success "Created Grafana instance: $GRAFANA_NAME"
    fi
    info "  Grafana ID: $grafana_id"

    # -- Log Analytics Workspace --
    step "Checking Log Analytics workspace: $LOGS_WORKSPACE_NAME..."
    local logs_id
    logs_id=$(az monitor log-analytics workspace show \
        --workspace-name "$LOGS_WORKSPACE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv 2>/dev/null || true)

    if [[ -n "$logs_id" ]]; then
        info "  Log Analytics workspace already exists: $LOGS_WORKSPACE_NAME"
    else
        step "Creating Log Analytics workspace: $LOGS_WORKSPACE_NAME..."
        if [[ "$DRY_RUN" == "true" ]]; then
            dry_run_cmd az monitor log-analytics workspace create \
                -g "$RESOURCE_GROUP" -n "$LOGS_WORKSPACE_NAME" --query id -o tsv
            logs_id="<DRY_RUN_LOGS_ID>"
        else
            logs_id=$(az monitor log-analytics workspace create \
                -g "$RESOURCE_GROUP" \
                -n "$LOGS_WORKSPACE_NAME" \
                --query id -o tsv)
        fi
        success "Created Log Analytics workspace: $LOGS_WORKSPACE_NAME"
    fi
    info "  Log Analytics workspace ID: $logs_id"

    # Export IDs for use in later steps
    AZURE_MONITOR_WORKSPACE_ID="$monitor_id"
    GRAFANA_ID="$grafana_id"
    LOG_ANALYTICS_WORKSPACE_ID="$logs_id"

    success "All Azure monitoring resources ready"
}

# ============================================================================
# STEP 4: ENABLE METRICS COLLECTION
# ============================================================================

enable_metrics_collection() {
    section "Step 4/8: Enabling Metrics and Container Insights on Cluster"

    # -- azuremonitor-metrics (Managed Prometheus) --
    step "Checking azuremonitor-metrics extension on cluster $CLUSTER_NAME..."
    local metrics_state
    metrics_state=$(az k8s-extension show \
        --name azuremonitor-metrics \
        --cluster-name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters \
        --query provisioningState -o tsv 2>/dev/null || echo "NotFound")

    if [[ "$metrics_state" == "Succeeded" ]]; then
        info "  azuremonitor-metrics extension already installed (Succeeded)"
    else
        step "Installing azuremonitor-metrics extension (links Monitor workspace + Grafana)..."
        run_cmd az k8s-extension create \
            --name azuremonitor-metrics \
            --cluster-name "$CLUSTER_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --cluster-type connectedClusters \
            --extension-type Microsoft.AzureMonitor.Containers.Metrics \
            --configuration-settings \
                azure-monitor-workspace-resource-id="${AZURE_MONITOR_WORKSPACE_ID}" \
                grafana-resource-id="${GRAFANA_ID}"
        success "azuremonitor-metrics extension installed"
    fi

    # -- azuremonitor-containers (Container Insights) --
    step "Checking azuremonitor-containers extension on cluster $CLUSTER_NAME..."
    local containers_state
    containers_state=$(az k8s-extension show \
        --name azuremonitor-containers \
        --cluster-name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters \
        --query provisioningState -o tsv 2>/dev/null || echo "NotFound")

    if [[ "$containers_state" == "Succeeded" ]]; then
        info "  azuremonitor-containers extension already installed (Succeeded)"
    else
        step "Installing azuremonitor-containers extension (Container Insights logs)..."
        run_cmd az k8s-extension create \
            --name azuremonitor-containers \
            --cluster-name "$CLUSTER_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --cluster-type connectedClusters \
            --extension-type Microsoft.AzureMonitor.Containers \
            --configuration-settings \
                logAnalyticsWorkspaceResourceID="${LOG_ANALYTICS_WORKSPACE_ID}"
        success "azuremonitor-containers extension installed"
    fi

    success "Cluster metrics collection enabled"
}

# ============================================================================
# STEP 5: DEPLOY OPENTELEMETRY COLLECTOR
# ============================================================================

deploy_otel_collector() {
    section "Step 5/8: Deploying OpenTelemetry Collector (in-cluster)"

    # Ensure namespace exists
    step "Ensuring namespace $OTEL_NAMESPACE exists..."
    if kubectl get namespace "$OTEL_NAMESPACE" &>/dev/null; then
        info "  Namespace $OTEL_NAMESPACE already exists"
    else
        run_cmd kubectl create namespace "$OTEL_NAMESPACE"
        success "Created namespace: $OTEL_NAMESPACE"
    fi

    # Write otel-collector-values.yaml
    local values_file="/tmp/otel-collector-values.yaml"
    step "Writing OTel Collector Helm values to $values_file..."

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "$values_file" << EOF
mode: deployment
fullnameOverride: ${OTEL_FULLNAME}
image:
  repository: otel/opentelemetry-collector
  tag: ${OTEL_IMAGE_TAG}

config:
  processors:
    memory_limiter:
      limit_percentage: 80
      spike_limit_percentage: 10
      check_interval: ${OTEL_CHECK_INTERVAL}s

  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: ":${OTEL_GRPC_PORT}"
        http:
          endpoint: ":4318"

  exporters:
    prometheus:
      endpoint: ":8889"
      resource_to_telemetry_conversion:
        enabled: true
      add_metric_suffixes: false

  service:
    extensions:
      - health_check

    telemetry:
      metrics:
        level: none

    pipelines:
      metrics:
        receivers:
          - otlp
        exporters:
          - prometheus

resources:
  limits:
    cpu: "100m"
    memory: "512Mi"

ports:
  metrics:
    enabled: true
    containerPort: 8889
    servicePort: 8889
    protocol: TCP
EOF
        success "OTel Collector values written"
    else
        dry_run_cmd "cat > $values_file << EOF ... (otel-collector-values.yaml)"
    fi

    # Add Helm repo
    step "Adding open-telemetry Helm repo..."
    run_cmd helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
    run_cmd helm repo update

    # Deploy or upgrade
    step "Deploying OTel Collector via Helm (helm upgrade --install)..."
    run_cmd helm upgrade --install aio-observability \
        open-telemetry/opentelemetry-collector \
        -f "$values_file" \
        --namespace "$OTEL_NAMESPACE"

    success "OpenTelemetry Collector deployed"

    # Wait for pod to be ready
    if [[ "$DRY_RUN" != "true" ]]; then
        step "Waiting for OTel Collector pod to be ready (up to 2 minutes)..."
        if kubectl rollout status deployment/"${OTEL_FULLNAME}" \
            -n "$OTEL_NAMESPACE" --timeout=120s; then
            success "OTel Collector pod is ready"
        else
            warn "OTel Collector pod not ready within 2 minutes - continuing anyway"
            warn "Check status: kubectl get pods -n $OTEL_NAMESPACE"
        fi
    fi
}

# ============================================================================
# STEP 6: CONFIGURE PROMETHEUS SCRAPING
# ============================================================================

configure_prometheus_scraping() {
    section "Step 6/8: Configuring Prometheus Metrics Scraping"

    local cm_file="/tmp/ama-metrics-prometheus-config.yaml"
    step "Writing Prometheus scrape ConfigMap to $cm_file..."

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "$cm_file" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ama-metrics-prometheus-config
  namespace: kube-system
data:
  prometheus-config: |2-
    scrape_configs:
      - job_name: otel
        scrape_interval: 1m
        static_configs:
          - targets:
            - aio-otel-collector.azure-iot-operations.svc.cluster.local:8889
      - job_name: aio-annotated-pod-metrics
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - action: drop
            regex: true
            source_labels:
              - __meta_kubernetes_pod_container_init
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scrape
          - action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            source_labels:
              - __address__
              - __meta_kubernetes_pod_annotation_prometheus_io_port
            target_label: __address__
          - action: replace
            source_labels:
              - __meta_kubernetes_namespace
            target_label: kubernetes_namespace
          - action: keep
            regex: 'azure-iot-operations'
            source_labels:
              - kubernetes_namespace
        scrape_interval: 1m
EOF
        success "Prometheus ConfigMap written"
    else
        dry_run_cmd "cat > $cm_file << 'EOF' ... (ama-metrics-prometheus-config.yaml)"
    fi

    step "Applying Prometheus scrape ConfigMap to cluster..."
    run_cmd kubectl apply -f "$cm_file"
    success "Prometheus scrape ConfigMap applied"
}

# ============================================================================
# STEP 7: CONFIGURE AIO OBSERVABILITY
# ============================================================================

configure_aio_observability() {
    section "Step 7/8: Configuring AIO Instance for Observability"

    # Auto-detect instance name if not provided
    if [[ -z "$INSTANCE_NAME" ]]; then
        step "Auto-detecting AIO instance name in resource group $RESOURCE_GROUP..."
        INSTANCE_NAME=$(az iot ops list \
            --resource-group "$RESOURCE_GROUP" \
            --query "[0].name" -o tsv 2>/dev/null || true)

        if [[ -z "$INSTANCE_NAME" ]]; then
            warn "Could not auto-detect AIO instance name."
            warn "Skipping 'az iot ops upgrade' step."
            warn "Run manually: az iot ops upgrade -g $RESOURCE_GROUP -n <instance-name> \\"
            warn "  --ops-config observability.metrics.openTelemetryCollectorAddress=${OTEL_FULLNAME}.${OTEL_NAMESPACE}.svc.cluster.local:${OTEL_GRPC_PORT} \\"
            warn "  --ops-config observability.metrics.exportInternalSeconds=${OTEL_CHECK_INTERVAL}"
            return 0
        fi
        info "  Detected AIO instance: $INSTANCE_NAME"
    fi

    local otel_address="${OTEL_FULLNAME}.${OTEL_NAMESPACE}.svc.cluster.local:${OTEL_GRPC_PORT}"

    step "Upgrading AIO instance '$INSTANCE_NAME' with observability config..."
    info "  OTel collector address: $otel_address"
    info "  Export interval:        ${OTEL_CHECK_INTERVAL}s"

    run_cmd az iot ops upgrade \
        --resource-group "$RESOURCE_GROUP" \
        --name "$INSTANCE_NAME" \
        --ops-config "observability.metrics.openTelemetryCollectorAddress=${otel_address}" \
        --ops-config "observability.metrics.exportInternalSeconds=${OTEL_CHECK_INTERVAL}"

    success "AIO instance observability configured"
}

# ============================================================================
# STEP 8: IMPORT GRAFANA DASHBOARDS
# ============================================================================

import_grafana_dashboards() {
    section "Step 8/8: Importing AIO Grafana Dashboards"

    local dashboard_url="https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/observability/grafana-dashboard/aio-observability.json"
    local dashboard_file="/tmp/aio-observability.json"

    step "Downloading AIO Grafana dashboard from GitHub..."
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_cmd curl -fsSL -o "$dashboard_file" "$dashboard_url"
    else
        if ! curl -fsSL -o "$dashboard_file" "$dashboard_url"; then
            warn "Failed to download dashboard JSON. Skipping import."
            warn "You can import manually from:"
            warn "  https://github.com/Azure-Samples/explore-iot-operations/tree/main/samples/observability/grafana-dashboard"
            return 0
        fi
        success "Dashboard JSON downloaded: $dashboard_file"
    fi

    step "Getting Grafana endpoint URL..."
    local grafana_url
    grafana_url=$(az grafana show \
        --name "$GRAFANA_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query properties.endpoint -o tsv 2>/dev/null || true)

    if [[ -n "$grafana_url" ]]; then
        info "  Grafana URL: $grafana_url"
    fi

    step "Importing dashboard to Grafana instance '$GRAFANA_NAME'..."
    run_cmd az grafana dashboard import \
        --name "$GRAFANA_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --definition "$dashboard_file" \
        --overwrite

    success "Grafana dashboard imported successfully"
    if [[ -n "$grafana_url" ]]; then
        log "Access your Grafana dashboards at: $grafana_url"
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================

print_summary() {
    section "Installation Complete"
    echo ""
    log "Observability stack deployed successfully!"
    echo ""
    info "Resources created/verified:"
    info "  Azure Monitor Workspace:  $WORKSPACE_NAME"
    info "  Azure Managed Grafana:    $GRAFANA_NAME"
    info "  Log Analytics Workspace:  $LOGS_WORKSPACE_NAME"
    info "  OTel Collector:           $OTEL_FULLNAME (namespace: $OTEL_NAMESPACE)"
    info "  Prometheus ConfigMap:     ama-metrics-prometheus-config (kube-system)"
    [[ -n "$INSTANCE_NAME" ]] && info "  AIO Instance:             $INSTANCE_NAME"
    echo ""
    info "Useful commands:"
    info "  Check OTel pods:    kubectl get pods -n $OTEL_NAMESPACE"
    info "  Check scrape config: kubectl get configmap ama-metrics-prometheus-config -n kube-system -o yaml"
    info "  Check extensions:   az k8s-extension list -g $RESOURCE_GROUP --cluster-name $CLUSTER_NAME --cluster-type connectedClusters -o table"
    info "  Open Grafana:       az grafana show --name $GRAFANA_NAME -g $RESOURCE_GROUP --query properties.endpoint -o tsv"
    echo ""
    info "Log file: $LOG_FILE"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_args "$@"
    setup_logging

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN MODE: No changes will be made"
        echo ""
    fi

    check_prerequisites
    load_config

    if [[ "$SKIP_AZURE" != "true" ]]; then
        register_providers
        install_cli_extensions
        create_azure_resources
        enable_metrics_collection
    else
        warn "Skipping Azure resource creation (--skip-azure flag set)"
        warn "Ensure AZURE_MONITOR_WORKSPACE_ID, GRAFANA_ID, and LOG_ANALYTICS_WORKSPACE_ID"
        warn "are available if needed for cluster extension steps."
    fi

    deploy_otel_collector
    configure_prometheus_scraping
    configure_aio_observability

    if [[ "$SKIP_DASHBOARDS" != "true" && "$SKIP_AZURE" != "true" ]]; then
        import_grafana_dashboards
    else
        info "Skipping Grafana dashboard import"
    fi

    print_summary
}

main "$@"
