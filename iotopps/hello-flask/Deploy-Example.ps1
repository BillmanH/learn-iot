# Quick Deploy Example
# Uses configuration from hello_flask_config.json with optional overrides

param(
    [string]$RegistryName,    # Override registry name from config
    [string]$RegistryType,    # Override registry type from config  
    [string]$ImageTag,        # Override image tag from config
    [string]$EdgeDeviceIP,    # Optional: Direct SSH to edge device
    [string]$EdgeDeviceUser   # Optional: SSH user for edge device
)

# Load configuration from JSON file
$HelloFlaskConfigPath = "$PSScriptRoot\hello_flask_config.json"
$config = $null

if (Test-Path $HelloFlaskConfigPath) {
    try {
        $config = Get-Content $HelloFlaskConfigPath | ConvertFrom-Json
        Write-Host "[CONFIG] Loaded configuration from hello_flask_config.json" -ForegroundColor Green
    } catch {
        Write-Host "[WARNING] Failed to parse hello_flask_config.json: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[INFO] Continuing with parameters only..." -ForegroundColor Yellow
    }
}

# Set configuration values with priority: Parameter > Config > Default
if (-not $RegistryName -and $config.registry.name) {
    $RegistryName = $config.registry.name
}
if (-not $RegistryType -and $config.registry.type) {
    $RegistryType = $config.registry.type
}
if (-not $ImageTag -and $config.image.tag) {
    $ImageTag = $config.image.tag
}

# Set defaults if still not specified
if (-not $RegistryName) { $RegistryName = "your-dockerhub-username" }
if (-not $RegistryType) { $RegistryType = "dockerhub" }
if (-not $ImageTag) { $ImageTag = "latest" }

# Validate registry name
if ($RegistryName -eq "your-dockerhub-username") {
    Write-Host "[ERROR] Please set registry name in hello_flask_config.json or use -RegistryName parameter" -ForegroundColor Red
    Write-Host "[INFO] Edit hello_flask_config.json and set registry.name, or use: .\Deploy-Example.ps1 -RegistryName 'your-username'" -ForegroundColor Yellow
    exit 1
}

# Build deployment command
$deployCommand = ".\Deploy-ToIoTEdge.ps1 -RegistryName '$RegistryName' -RegistryType '$RegistryType' -ImageTag '$ImageTag'"

# Add edge device parameters if specified
if ($EdgeDeviceIP) {
    $deployCommand += " -EdgeDeviceIP '$EdgeDeviceIP'"
}
if ($EdgeDeviceUser) {
    $deployCommand += " -EdgeDeviceUser '$EdgeDeviceUser'"
}

Write-Host "[DEPLOY] Executing deployment with configuration:" -ForegroundColor Cyan
Write-Host "  Registry: $RegistryType/$RegistryName" -ForegroundColor White
Write-Host "  Image Tag: $ImageTag" -ForegroundColor White
if ($EdgeDeviceIP) {
    Write-Host "  Edge Device: $EdgeDeviceUser@$EdgeDeviceIP" -ForegroundColor White
}
Write-Host ""

# Execute deployment
Write-Host "[EXEC] Running: $deployCommand" -ForegroundColor Yellow
Invoke-Expression $deployCommand
