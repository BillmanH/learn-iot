# ==============================================================================
# pre-provision.ps1
# Runs before `azd provision` (Bicep deployment).
# Responsibilities:
#   1. Resolve the deploying user's Entra Object ID  → AZURE_DEPLOYER_OBJECT_ID
#   2. Generate an RSA SSH key pair and store in azd env → AZURE_VM_SSH_PUBLIC_KEY
#      Skip generation if AZURE_VM_SSH_PUBLIC_KEY is already set (user-supplied key).
#   3. Apply sensible defaults for optional env vars that have not been set.
# ==============================================================================
# Usage: called automatically by `azd up` via azure.yaml preProvision hook.
#        Can also be run manually: pwsh scripts/pre-provision.ps1
# ==============================================================================

param(
    [switch]$DryRun  # Print what would be set without actually setting it
)

$ErrorActionPreference = 'Stop'

function Set-AzdEnvIfEmpty {
    param([string]$Key, [string]$Value)
    $current = azd env get-value $Key 2>$null
    if (-not $current) {
        if (-not $DryRun) {
            azd env set $Key $Value
        }
        Write-Host "  set   $Key = $Value"
    } else {
        Write-Host "  skip  $Key (already set)"
    }
}

# ---------------------------------------------------------------------------
# Simple flat-YAML reader — handles lines of the form:  key: value
# Lines starting with # or blank lines are ignored.
# ---------------------------------------------------------------------------
function Read-ConfigYaml {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.+)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim() -replace '\s*#.*$', ''   # strip inline comments
            $result[$k] = $v
        }
    }
    return $result
}

Write-Host ""
Write-Host "=== Pre-Provision Hook ==="

# ---------------------------------------------------------------------------
# 0. Load config.yaml (user-facing config, lives next to azure.yaml)
# ---------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot '..\config.yaml'
$config = Read-ConfigYaml -Path $configPath

if ($config.Count -gt 0) {
    Write-Host "[0] Loaded config.yaml ($($config.Count) values)"
} else {
    Write-Host "[0] No config.yaml found — using defaults"
}

# Map config.yaml keys → azd env variable names
$configMap = @{
    # Core Azure — azd built-ins
    'subscription_id'            = 'AZURE_SUBSCRIPTION_ID'
    'location'                   = 'AZURE_LOCATION'
    'resource_group'             = 'AZURE_RESOURCE_GROUP'
    # VM
    'vm_size'                    = 'AZURE_VM_SIZE'
    'vm_admin_username'          = 'AZURE_VM_ADMIN_USERNAME'
    'open_ssh_port'              = 'OPEN_SSH_PORT'
    # Optional tools
    'install_k9s'                = 'INSTALL_K9S'
    'install_mqttui'             = 'INSTALL_MQTTUI'
    # Modules
    'deploy_module_edgemqttsim'  = 'DEPLOY_MODULE_EDGEMQTTSIM'
    'deploy_module_sputnik'      = 'DEPLOY_MODULE_SPUTNIK'
    'deploy_module_hello_flask'  = 'DEPLOY_MODULE_HELLO_FLASK'
    'deploy_module_demohistorian'= 'DEPLOY_MODULE_DEMOHISTORIAN'
}

foreach ($yamlKey in $configMap.Keys) {
    if ($config.ContainsKey($yamlKey)) {
        $val = $config[$yamlKey] -replace '^["'']|["'']$', ''   # strip surrounding quotes
        if ($val -ne '') {
            Set-AzdEnvIfEmpty -Key $configMap[$yamlKey] -Value $val
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Resolve deployer object ID
# ---------------------------------------------------------------------------
Write-Host "[1/3] Resolving deployer Entra Object ID..."

$deployerObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $deployerObjectId) {
    Write-Error "Could not resolve current user's Entra object ID. Are you logged in? Run: az login"
    exit 1
}
Set-AzdEnvIfEmpty -Key 'AZURE_DEPLOYER_OBJECT_ID' -Value $deployerObjectId
Write-Host "  Deployer Object ID: $deployerObjectId"

# ---------------------------------------------------------------------------
# 2. SSH key — generate if not already provided
# ---------------------------------------------------------------------------
Write-Host "[2/3] Checking SSH key..."

$existingSshKey = azd env get-value AZURE_VM_SSH_PUBLIC_KEY 2>$null
if ($existingSshKey) {
    Write-Host "  AZURE_VM_SSH_PUBLIC_KEY already set — using existing key."
} else {
    Write-Host "  Generating new RSA-4096 SSH key pair..."
    $keyPath = Join-Path $PSScriptRoot '.azure-vm-key'
    if (Test-Path $keyPath)        { Remove-Item $keyPath -Force }
    if (Test-Path "$keyPath.pub")  { Remove-Item "$keyPath.pub" -Force }

    ssh-keygen -t rsa -b 4096 -f $keyPath -N '""' -C 'azd-aio-vm' | Out-Null
    $pubKey = Get-Content "$keyPath.pub"

    if (-not $DryRun) {
        azd env set AZURE_VM_SSH_PUBLIC_KEY $pubKey
        azd env set AZURE_VM_SSH_PRIVATE_KEY_PATH $keyPath
    }
    Write-Host "  SSH key generated -> $keyPath"
    Write-Host "  NOTE: Keep this private key file — it is NOT stored in Key Vault."
}

# ---------------------------------------------------------------------------
# 3. Hard defaults for anything still unset
# ---------------------------------------------------------------------------
Write-Host "[3/3] Applying fallback defaults..."

Set-AzdEnvIfEmpty -Key 'AZURE_VM_ADMIN_USERNAME' -Value 'aiouser'
Set-AzdEnvIfEmpty -Key 'AZURE_VM_SIZE'           -Value 'Standard_D4s_v3'
Set-AzdEnvIfEmpty -Key 'OPEN_SSH_PORT'            -Value 'true'
Set-AzdEnvIfEmpty -Key 'INSTALL_K9S'              -Value 'false'
Set-AzdEnvIfEmpty -Key 'INSTALL_MQTTUI'           -Value 'false'

Write-Host ""
Write-Host "=== Pre-Provision Complete ==="
Write-Host ""
