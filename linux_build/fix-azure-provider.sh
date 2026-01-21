#!/bin/bash
# Quick fix script to install Azure Key Vault Provider for CSI Secret Store
# Run this on the edge device if the Azure provider is missing

set -e

echo "==============================================="
echo "Installing Azure Key Vault Provider for CSI"
echo "==============================================="

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
    echo "ERROR: Helm is not installed. Please run linux_installer.sh first."
    exit 1
fi

# Check if CSI driver is installed
if ! kubectl get csidriver secrets-store.csi.k8s.io &>/dev/null; then
    echo "ERROR: CSI Secret Store driver not found. Please run linux_installer.sh first."
    exit 1
fi

echo "✓ CSI Secret Store driver is installed"

# Check if Azure provider already exists
if kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure &>/dev/null 2>&1; then
    echo "✓ Azure Key Vault provider is already installed"
    kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure
    exit 0
fi

echo ""
echo "Installing Azure Key Vault Provider..."

# Add Helm repo
helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm repo update

# Install Azure provider
helm install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
    --namespace kube-system \
    --set secrets-store-csi-driver.install=false

echo ""
echo "Waiting for Azure provider pods to be ready..."
sleep 10

# Wait for pods
kubectl wait --for=condition=ready pod \
    -l app=csi-secrets-store-provider-azure \
    -n kube-system \
    --timeout=120s || echo "WARNING: Pods may not be fully ready yet"

echo ""
echo "==============================================="
echo "Verification"
echo "==============================================="

# Verify
if kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure &>/dev/null 2>&1; then
    echo "✓ Azure Key Vault provider pods:"
    kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure
    echo ""
    echo "✓ Installation successful!"
else
    echo "✗ Azure provider pods not found"
    exit 1
fi
