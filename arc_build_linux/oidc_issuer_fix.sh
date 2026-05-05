#!/bin/bash

# ============================================================================
# K3s OIDC Issuer Fix for Azure Arc Secret Sync
# ============================================================================
# Fixes AADSTS700211: "No matching federated identity record found for
# presented assertion issuer 'https://kubernetes.default.svc.cluster.local'"
#
# Root cause: K3s issues service account tokens with the default issuer URL,
# but Azure AD federated identity credentials expect the Arc OIDC issuer URL.
# This script reconfigures K3s to use the correct Arc OIDC issuer and restarts
# the service, then triggers SecretSync objects to retry.
#
# Requirements:
#   - Run ON the NUC (Linux edge device) as a user with sudo privileges
#   - Azure CLI installed and authenticated (az login)
#   - kubectl available
#   - jq installed
#   - aio_config.json present at ../config/aio_config.json
#
# Usage:
#   chmod +x oidc_issuer_fix.sh
#   ./oidc_issuer_fix.sh
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/aio_config.json"
K3S_CONFIG_FILE="/etc/rancher/k3s/config.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
info()    { echo -e "${BLUE}[$(date +'%H:%M:%S')] INFO: $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARN: $1${NC}"; }
error()   { echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[$(date +'%H:%M:%S')] SUCCESS: $1${NC}"; }

echo "============================================================================"
echo "K3s OIDC Issuer Fix"
echo "============================================================================"
echo ""

# ----------------------------------------------------------------------------
# Check prerequisites
# ----------------------------------------------------------------------------
log "Checking prerequisites..."

command -v jq      &>/dev/null || error "jq not found. Install with: sudo apt-get install -y jq"
command -v az      &>/dev/null || error "Azure CLI not found. See https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
command -v kubectl &>/dev/null || error "kubectl not found."

[[ -f "$CONFIG_FILE" ]] || error "Config file not found: $CONFIG_FILE"

az account show &>/dev/null || error "Not logged in to Azure CLI. Run: az login"
success "Prerequisites OK"

# ----------------------------------------------------------------------------
# Load config
# ----------------------------------------------------------------------------
log "Loading configuration from $CONFIG_FILE..."

CLUSTER_NAME=$(jq -r '.azure.cluster_name // empty' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.azure.resource_group // empty' "$CONFIG_FILE")
SUBSCRIPTION_ID=$(jq -r '.azure.subscription_id // empty' "$CONFIG_FILE")

[[ -z "$CLUSTER_NAME" ]]    && error "Missing 'azure.cluster_name' in $CONFIG_FILE"
[[ -z "$RESOURCE_GROUP" ]]  && error "Missing 'azure.resource_group' in $CONFIG_FILE"
[[ -z "$SUBSCRIPTION_ID" ]] && error "Missing 'azure.subscription_id' in $CONFIG_FILE"

info "  Cluster:        $CLUSTER_NAME"
info "  Resource Group: $RESOURCE_GROUP"
info "  Subscription:   $SUBSCRIPTION_ID"

# ----------------------------------------------------------------------------
# Get Arc OIDC issuer URL
# ----------------------------------------------------------------------------
log "Fetching Arc OIDC issuer URL from Azure..."

az account set -s "$SUBSCRIPTION_ID"

OIDC_ISSUER=$(az connectedk8s show \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "oidcIssuerProfile.issuerUrl" -o tsv 2>/dev/null || true)

if [[ -z "$OIDC_ISSUER" ]]; then
    error "Could not retrieve OIDC issuer URL. Ensure the cluster is connected to Arc and OIDC is enabled.\nCheck: az connectedk8s show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
fi

success "OIDC issuer URL: $OIDC_ISSUER"

# Verify it's not the default (broken) issuer
if [[ "$OIDC_ISSUER" == "https://kubernetes.default.svc.cluster.local" ]]; then
    error "OIDC issuer is still the default K3s value. OIDC may not be enabled on the Arc cluster.\nRun: az connectedk8s update --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --enable-oidc-issuer"
fi

# ----------------------------------------------------------------------------
# Check current K3s config
# ----------------------------------------------------------------------------
log "Checking current K3s config..."

if [[ -f "$K3S_CONFIG_FILE" ]]; then
    info "  Current contents of $K3S_CONFIG_FILE:"
    cat "$K3S_CONFIG_FILE" | sed 's/^/    /'
    echo ""
    warn "  This file will be updated with the correct OIDC issuer."
else
    info "  $K3S_CONFIG_FILE does not exist yet — will be created."
fi

# ----------------------------------------------------------------------------
# Confirm before proceeding (K3s restart will briefly interrupt the cluster)
# ----------------------------------------------------------------------------
echo ""
warn "This will restart K3s. All pods will briefly restart (~60-90 seconds of disruption)."
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ----------------------------------------------------------------------------
# Write K3s config
# ----------------------------------------------------------------------------
log "Writing K3s config with correct OIDC issuer..."

sudo mkdir -p /etc/rancher/k3s

sudo tee "$K3S_CONFIG_FILE" > /dev/null << EOF
kube-apiserver-arg:
  - "service-account-issuer=${OIDC_ISSUER}"
  - "service-account-jwks-uri=${OIDC_ISSUER}/openid/v1/jwks"
EOF

success "Wrote $K3S_CONFIG_FILE"
info "  service-account-issuer: $OIDC_ISSUER"
info "  service-account-jwks-uri: ${OIDC_ISSUER}/openid/v1/jwks"

# ----------------------------------------------------------------------------
# Restart K3s
# ----------------------------------------------------------------------------
log "Restarting K3s service..."
sudo systemctl restart k3s

log "Waiting for K3s API server to become available (up to 3 minutes)..."
TIMEOUT=180
ELAPSED=0
until kubectl get nodes &>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        error "K3s API server did not become available after ${TIMEOUT}s.\nCheck: sudo systemctl status k3s\nLogs:  sudo journalctl -u k3s -n 50"
    fi
    echo -n "."
done
echo ""
success "K3s API server is up"

# ----------------------------------------------------------------------------
# Verify nodes ready
# ----------------------------------------------------------------------------
log "Waiting for node to be Ready (up to 2 minutes)..."
TIMEOUT=120
ELAPSED=0
until kubectl get nodes | grep -q " Ready"; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        warn "Node not Ready after ${TIMEOUT}s — continuing anyway"
        kubectl get nodes
        break
    fi
    echo -n "."
done
echo ""
kubectl get nodes
success "Cluster is healthy"

# ----------------------------------------------------------------------------
# Verify the issuer is applied
# ----------------------------------------------------------------------------
log "Verifying issuer in cluster token..."
CURRENT_ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | jq -r '.issuer' || echo "unknown")
info "  Reported OIDC issuer: $CURRENT_ISSUER"

if [[ "$CURRENT_ISSUER" == "$OIDC_ISSUER" ]]; then
    success "Issuer matches Arc OIDC URL — fix applied correctly"
else
    warn "Issuer mismatch: got '$CURRENT_ISSUER', expected '$OIDC_ISSUER'"
    warn "The API server may still be initializing. Wait 30s and re-check:"
    warn "  kubectl get --raw /.well-known/openid-configuration | jq '.issuer'"
fi

# ----------------------------------------------------------------------------
# Force SecretSync objects to retry
# ----------------------------------------------------------------------------
log "Triggering SecretSync objects to retry..."

SECRETSYNCS=$(kubectl get secretsync -n azure-iot-operations --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)

if [[ -z "$SECRETSYNCS" ]]; then
    warn "No SecretSync objects found in azure-iot-operations — skipping retry trigger"
else
    while IFS= read -r ss; do
        [[ -z "$ss" ]] && continue
        info "  Annotating SecretSync: $ss"
        kubectl annotate secretsync "$ss" -n azure-iot-operations \
            "oidc-fix-trigger=$(date +%s)" --overwrite
        success "  Triggered: $ss"
    done <<< "$SECRETSYNCS"
fi

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
echo ""
echo "============================================================================"
success "OIDC issuer fix complete!"
echo "============================================================================"
echo ""
info "Next steps:"
info "  1. Wait 2-3 minutes for SecretSync to pull secrets from Key Vault"
info "  2. Verify secrets landed:"
info "       kubectl get secret -n azure-iot-operations | grep tapo"
info "  3. Check SecretSync status:"
info "       kubectl get secretsync -n azure-iot-operations"
info "  4. Check device health in the AIO portal or:"
info "       kubectl get devices.namespaces.deviceregistry.microsoft.com -n azure-iot-operations"
echo ""
