# Build-WasmModule.ps1
# Builds the Rust WASM module locally and pushes both OCI artifacts to ACR.
#
# AIO DataflowGraphs require the .wasm binary to be stored as an OCI artifact
# (NOT a Docker container image).  This script:
#   1. Ensures the wasm32-wasip2 Rust target is installed
#   2. Builds the module locally with cargo
#   3. Logs in to ACR
#   4. Pushes the .wasm binary with the correct AIO artifact type
#   5. Pushes the graph definition YAML with the correct AIO artifact type
#
# Prerequisites (Windows development machine):
#   - Rust toolchain:  https://rustup.rs
#   - ORAS CLI:        winget install oras-project.oras
#   - Azure CLI:       winget install Microsoft.AzureCLI
#
# Usage:
#   .\Build-WasmModule.ps1
#   .\Build-WasmModule.ps1 -Tag v1.0.0
#   .\Build-WasmModule.ps1 -RegistryName myacr -SkipGraphPush
#
# IMPORTANT: Do NOT use special characters or emojis in this file.

[CmdletBinding()]
param(
    # ACR name (without .azurecr.io). If omitted, read from ../../config/aio_config.json
    [string]$RegistryName = "",

    [string]$Tag = "latest",
    [string]$WasmRepository  = "factory-transform-wasm",
    [string]$GraphRepository = "factory-transform-graph",

    # Skip pushing the graph definition YAML (push wasm only)
    [switch]$SkipGraphPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot

$WasmArtifactType  = "application/vnd.module.wasm.content.layer.v1+wasm"
$GraphArtifactType = "application/vnd.microsoft.aio.graph.v1+yaml"

# -- Helpers -------------------------------------------------------------------
function Write-Step([string]$msg) {
    Write-Host "`n[BUILD] $msg" -ForegroundColor Cyan
}

function Assert-Command([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$cmd' not found. Install it and retry."
    }
}

# -- Resolve registry name from aio_config.json if not supplied ----------------
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

$AcrHost      = "$RegistryName.azurecr.io"
$WasmRef      = "${AcrHost}/${WasmRepository}:${Tag}"
$GraphRef     = "${AcrHost}/${GraphRepository}:${Tag}"
$WasmBinary   = Join-Path $ScriptDir "target\wasm32-wasip2\release\factory_transform_wasm.wasm"
$GraphYaml    = Join-Path $ScriptDir "graph.yaml"

# -- 0. Verify tooling ---------------------------------------------------------
Write-Step "Checking tooling"
Assert-Command "cargo"
Assert-Command "rustup"
Assert-Command "oras"
Assert-Command "az"

# -- 1. Ensure wasm32-wasip2 target is installed --------------------------------
Write-Step "Ensuring Rust target wasm32-wasip2 is installed"
rustup target add wasm32-wasip2
if ($LASTEXITCODE -ne 0) { Write-Error "rustup target add wasm32-wasip2 failed." }

# -- 2. Build ------------------------------------------------------------------
Write-Step "Building wasm32-wasip2 release binary"
Push-Location $ScriptDir
try {
    cargo build --release --target wasm32-wasip2
    if ($LASTEXITCODE -ne 0) { Write-Error "cargo build failed." }
} finally {
    Pop-Location
}

if (-not (Test-Path $WasmBinary)) {
    Write-Error "Expected binary not found: $WasmBinary"
}
$size = (Get-Item $WasmBinary).Length
Write-Host "  Binary   : $WasmBinary ($size bytes)" -ForegroundColor DarkGray

# -- 3. ACR login --------------------------------------------------------------
Write-Step "Logging in to ACR $AcrHost"
az acr login --name $RegistryName
if ($LASTEXITCODE -ne 0) { Write-Error "az acr login failed." }

# -- 4. Push .wasm binary as OCI artifact -------------------------------------
Write-Step "Pushing WASM binary to $WasmRef"
oras push $WasmRef `
    --artifact-type $WasmArtifactType `
    "${WasmBinary}:${WasmArtifactType}"
if ($LASTEXITCODE -ne 0) { Write-Error "oras push (wasm binary) failed." }
Write-Host "  Pushed: $WasmRef" -ForegroundColor Green

# -- 5. Push graph definition YAML as OCI artifact ---------------------------
if (-not $SkipGraphPush) {
    if (-not (Test-Path $GraphYaml)) {
        Write-Warning "graph.yaml not found at $GraphYaml -- skipping graph push."
        Write-Warning "Create graph.yaml from the template in the README, then re-run."
    } else {
        Write-Step "Pushing graph definition to $GraphRef"
        Push-Location $ScriptDir
        try {
            oras push $GraphRef `
                --artifact-type $GraphArtifactType `
                "graph.yaml:${GraphArtifactType}"
            if ($LASTEXITCODE -ne 0) { Write-Error "oras push (graph YAML) failed." }
        } finally {
            Pop-Location
        }
        Write-Host "  Pushed: $GraphRef" -ForegroundColor Green
    }
}

# -- Done ---------------------------------------------------------------------
Write-Host ""
Write-Host "Build and push complete." -ForegroundColor Green
Write-Host "  WASM binary : $WasmRef"
if (-not $SkipGraphPush) {
    Write-Host "  Graph YAML  : $GraphRef"
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Register ACR as a registry endpoint in AIO (one-time):"
Write-Host "     az iot ops registry create --name factory-wasm-registry "
Write-Host "         --resource-group <rg> --instance <aio-instance> --registry $AcrHost"
Write-Host "  2. Open the AIO portal -> Dataflows -> Graphs -> New graph"
Write-Host "     and reference: $GraphRef"
Write-Host "  No SSH or kubectl required."
