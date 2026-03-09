# Build-OeeTransform.ps1
# Builds the OEE Transform Python module via Azure Container Registry Tasks.
# No local Docker, Rust, or ORAS required -- only Azure CLI.
#
# Usage:
#   .\Build-OeeTransform.ps1
#   .\Build-OeeTransform.ps1 -Tag v1.0.0
#   .\Build-OeeTransform.ps1 -RegistryName myacr
#
# After building, deploy with:
#   .\Deploy-OeeTransform.ps1
# or directly:
#   kubectl apply -f deployment.yaml  (after substituting YOUR_REGISTRY)
#
# IMPORTANT: Do NOT use special characters or emojis in this file.

[CmdletBinding()]
param(
    [string]$RegistryName = "",
    [string]$Tag          = "latest",
    [string]$ImageName    = "oee-transform"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot

# -- Resolve registry name from aio_config.json if not supplied ---------------
if (-not $RegistryName) {
    $ConfigPath = Join-Path $ScriptDir "..\..\config\aio_config.json"
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "No -RegistryName supplied and aio_config.json not found at $ConfigPath"
    }
    $AioConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $RawRegistry = $AioConfig.azure.container_registry
    if (-not $RawRegistry) {
        Write-Error "azure.container_registry is empty in $ConfigPath"
    }
    $RegistryName = $RawRegistry -replace '\.azurecr\.io$', ''
    Write-Host "[CONFIG] RegistryName resolved from aio_config.json: $RegistryName" -ForegroundColor DarkGray
}

function Write-Step([string]$msg) { Write-Host "`n[BUILD] $msg" -ForegroundColor Cyan }
function Assert-Command([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$cmd' not found. Install it and retry."
    }
}

# -- 0. Verify tooling ---------------------------------------------------------
Write-Step "Checking tooling"
Assert-Command "az"

$FullImage = "$RegistryName.azurecr.io/${ImageName}:${Tag}"

# -- 1. Build via ACR Tasks (runs entirely in the cloud) ----------------------
Write-Step "Queuing az acr build for $FullImage"
Write-Host "  Registry : $RegistryName"
Write-Host "  Image    : $FullImage"
Write-Host "  Context  : $ScriptDir"

az acr build `
    --registry $RegistryName `
    --image "${ImageName}:${Tag}" `
    --file (Join-Path $ScriptDir "Dockerfile") `
    $ScriptDir

if ($LASTEXITCODE -ne 0) { Write-Error "az acr build failed." }

Write-Host "`nBuild complete." -ForegroundColor Green
Write-Host "  Image: $FullImage" -ForegroundColor Green
Write-Host ""
Write-Host "To update deployment.yaml and deploy:" -ForegroundColor Yellow
Write-Host "  (Replace <YOUR_REGISTRY> with $RegistryName.azurecr.io)"
Write-Host "  kubectl apply -f $ScriptDir\deployment.yaml"
