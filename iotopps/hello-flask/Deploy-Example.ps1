# Quick Deploy Example
# Copy this file and customize for your environment

# === CONFIGURATION - UPDATE THESE VALUES ===
$REGISTRY_NAME = "your-dockerhub-username"  # REQUIRED: Your Docker Hub username or ACR name
$REGISTRY_TYPE = "dockerhub"                 # Options: "dockerhub" or "acr"
$IMAGE_TAG = "latest"                        # Optional: Image version tag

# Optional: For direct SSH connection to edge device
# $EDGE_DEVICE_IP = "192.168.1.100"
# $EDGE_DEVICE_USER = "azureuser"

# === END CONFIGURATION ===

# Validate registry name
if ($REGISTRY_NAME -eq "your-dockerhub-username") {
    Write-Host "ERROR: Please update REGISTRY_NAME in this script" -ForegroundColor Red
    Write-Host "Edit Deploy-Example.ps1 and set your Docker Hub username or ACR name"
    exit 1
}

# Build deployment command
$deployCommand = ".\Deploy-ToIoTEdge.ps1 -RegistryName '$REGISTRY_NAME' -RegistryType '$REGISTRY_TYPE' -ImageTag '$IMAGE_TAG'"

# Add edge device parameters if specified
if ($EDGE_DEVICE_IP) {
    $deployCommand += " -EdgeDeviceIP '$EDGE_DEVICE_IP'"
}
if ($EDGE_DEVICE_USER) {
    $deployCommand += " -EdgeDeviceUser '$EDGE_DEVICE_USER'"
}

Write-Host "Executing deployment with configuration:" -ForegroundColor Cyan
Write-Host "  Registry: $REGISTRY_TYPE/$REGISTRY_NAME"
Write-Host "  Image Tag: $IMAGE_TAG"
if ($EDGE_DEVICE_IP) {
    Write-Host "  Edge Device: $EDGE_DEVICE_USER@$EDGE_DEVICE_IP"
}
Write-Host ""

# Execute deployment
Invoke-Expression $deployCommand
