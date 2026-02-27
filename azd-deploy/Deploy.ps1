# ==============================================================================
# Deploy.ps1 - Turnkey wrapper for `azd up`
#
# USAGE:
#   cd azd-deploy
#   .\Deploy.ps1
#
# This script reads config.yaml, pre-seeds all azd environment variables
# (including generating an SSH key pair), and calls `azd up --no-prompt`
# so no interactive prompts appear.
#
# Prerequisites: az login  and  azd auth login  must have been run.
# ==============================================================================

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Read-ConfigYaml {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z0-9_]+)\s*:\s*"?([^"#]*)"?\s*(?:#.*)?$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim()
            if ($k -ne '' -and $v -ne '') { $result[$k] = $v }
        }
    }
    return $result
}

function Require-Config {
    param([hashtable]$Config, [string]$Key, [string]$Label)
    if (-not $Config.ContainsKey($Key) -or $Config[$Key] -eq '') {
        Write-Host ""
        Write-Host "ERROR: '$Key' is required in config.yaml but is not set."
        Write-Host "  Edit azd-deploy/config.yaml and set: $Key"
        if ($Label) { Write-Host "  Hint: $Label" }
        exit 1
    }
}

function Generate-SshPublicKey {
    # Generates an RSA-4096 public key in OpenSSH format using .NET Framework APIs.
    # Works on PowerShell 5.1 (.NET Framework 4.x) and PowerShell 7+.
    # Only the public key is needed — Azure ARM requires it to create the VM.
    # The private key is not saved; use az vm run-command for all VM access.
    param([string]$Comment = 'azd-aio-vm')

    $rsa    = New-Object System.Security.Cryptography.RSACryptoServiceProvider(4096)
    $params = $rsa.ExportParameters($false)  # public key parameters only

    function _SshBytes([byte[]]$b) {
        $len = [System.BitConverter]::GetBytes([uint32]$b.Length)
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($len) }
        return [byte[]]$len + [byte[]]$b
    }
    function _SshMPInt([byte[]]$b) {
        $s = 0; while ($s -lt $b.Length - 1 -and $b[$s] -eq 0) { $s++ }
        $t = $b[$s..($b.Length - 1)]
        if ($t[0] -band 0x80) { $t = [byte[]]@(0) + $t }
        return _SshBytes $t
    }

    $algBytes = [System.Text.Encoding]::ASCII.GetBytes('ssh-rsa')
    $blob   = (_SshBytes $algBytes) + (_SshMPInt $params.Exponent) + (_SshMPInt $params.Modulus)
    $pubKey = "ssh-rsa $([Convert]::ToBase64String($blob)) $Comment"

    $rsa.Dispose()
    return $pubKey
}

# ---------------------------------------------------------------------------
# 0. Read config.yaml
# ---------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot 'config.yaml'
if (-not (Test-Path $configPath)) {
    Write-Host ""
    Write-Host "ERROR: config.yaml not found at: $configPath"
    Write-Host "  Copy config.template.yaml to config.yaml and fill in your values:"
    Write-Host "  cp azd-deploy/config.template.yaml azd-deploy/config.yaml"
    exit 1
}

$c = Read-ConfigYaml -Path $configPath
Write-Host ""
Write-Host "=== AIO Turnkey Deployment ==="
Write-Host "[0] Loaded config.yaml ($($c.Count) values)"

# Validate required fields
Require-Config $c 'env_name'          'A short label for this deployment, e.g. aio-dev'
Require-Config $c 'subscription_id'   'Your Azure subscription ID: az account show --query id -o tsv'

$envName = $c['env_name']

# ---------------------------------------------------------------------------
# 1. Create or select the azd environment
# ---------------------------------------------------------------------------
Write-Host "[1] Setting up azd environment '$envName'..."

$existing = azd env list 2>$null | Select-String -Pattern "^\s*$envName\s"
if ($existing) {
    Write-Host "  Selecting existing environment '$envName'"
    azd env select $envName
} else {
    Write-Host "  Creating new environment '$envName'"
    azd env new $envName --no-prompt 2>&1 | Out-Null
    azd env select $envName
}

# ---------------------------------------------------------------------------
# 2. Pre-seed all azd env variables from config.yaml
# ---------------------------------------------------------------------------
Write-Host "[2] Seeding azd environment variables..."

$mapping = @{
    'subscription_id'             = 'AZURE_SUBSCRIPTION_ID'
    'location'                    = 'AZURE_LOCATION'
    'resource_group'              = 'AZURE_RESOURCE_GROUP'
    'vm_size'                     = 'AZURE_VM_SIZE'
    'vm_admin_username'           = 'AZURE_VM_ADMIN_USERNAME'
    'open_ssh_port'               = 'OPEN_SSH_PORT'
    'install_k9s'                 = 'INSTALL_K9S'
    'install_mqttui'              = 'INSTALL_MQTTUI'
    'deploy_module_edgemqttsim'   = 'DEPLOY_MODULE_EDGEMQTTSIM'
    'deploy_module_sputnik'       = 'DEPLOY_MODULE_SPUTNIK'
    'deploy_module_hello_flask'   = 'DEPLOY_MODULE_HELLO_FLASK'
    'deploy_module_demohistorian' = 'DEPLOY_MODULE_DEMOHISTORIAN'
}

foreach ($yamlKey in $mapping.Keys) {
    if ($c.ContainsKey($yamlKey) -and $c[$yamlKey] -ne '') {
        $envKey = $mapping[$yamlKey]
        azd env set $envKey $c[$yamlKey] | Out-Null
        Write-Host "  set $envKey = $($c[$yamlKey])"
    }
}

# Defaults for anything not in config
$defaults = @{
    'AZURE_VM_ADMIN_USERNAME' = 'aiouser'
    'AZURE_VM_SIZE'           = 'Standard_D4s_v3'
    'OPEN_SSH_PORT'           = 'true'
    'INSTALL_K9S'             = 'false'
    'INSTALL_MQTTUI'          = 'false'
    'DEPLOY_MODULE_EDGEMQTTSIM'   = 'false'
    'DEPLOY_MODULE_SPUTNIK'       = 'false'
    'DEPLOY_MODULE_HELLO_FLASK'   = 'false'
    'DEPLOY_MODULE_DEMOHISTORIAN' = 'false'
}
foreach ($k in $defaults.Keys) {
    $cur = azd env get-value $k 2>$null
    if (-not $cur) { azd env set $k $defaults[$k] | Out-Null }
}

# ---------------------------------------------------------------------------
# 3. Generate SSH key if not already present (valid key required by Azure ARM)
# ---------------------------------------------------------------------------
Write-Host "[3] Checking SSH key..."

$existingKey = azd env get-value AZURE_VM_SSH_PUBLIC_KEY 2>$null
# Check it looks like a real public key (starts with 'ssh-')
if ($existingKey -and $existingKey -match '^ssh-') {
    Write-Host "  Valid SSH public key already set - reusing."
} else {
    Write-Host "  Generating RSA-4096 SSH public key (no ssh-keygen required)..."
    $pubKey = Generate-SshPublicKey
    azd env set AZURE_VM_SSH_PUBLIC_KEY $pubKey | Out-Null
    Write-Host "  Public key generated and stored in azd env."
    Write-Host "  (Private key not saved - use az vm run-command for all VM access)"
}

# ---------------------------------------------------------------------------
# 4. Resolve deployer Object ID
# ---------------------------------------------------------------------------
Write-Host "[4] Resolving deployer Entra Object ID..."
$oid = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $oid) {
    Write-Host "  ERROR: Could not resolve Entra Object ID. Run: az login"
    exit 1
}
azd env set AZURE_DEPLOYER_OBJECT_ID $oid | Out-Null
Write-Host "  Object ID: $oid"

# ---------------------------------------------------------------------------
# 5. Ensure resource group exists (azd --no-prompt requires it to pre-exist)
# ---------------------------------------------------------------------------
$rg       = $c['resource_group']
$location = if ($c.ContainsKey('location')) { $c['location'] } else { 'eastus' }

if ($rg -and $rg -ne '') {
    Write-Host "[5] Ensuring resource group '$rg' exists..."
    $exists = az group exists --name $rg --subscription $c['subscription_id'] 2>$null
    if ($exists -eq 'true') {
        Write-Host "  Resource group already exists."
    } else {
        Write-Host "  Creating resource group '$rg' in '$location'..."
        az group create --name $rg --location $location --subscription $c['subscription_id'] | Out-Null
        Write-Host "  Created."
    }
} else {
    Write-Host "[5] No resource_group set in config.yaml - azd will auto-generate the name."
}

# ---------------------------------------------------------------------------
# 6. Run azd up
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== All variables set. Starting deployment... ==="
Write-Host "  This will take approximately 25-35 minutes."
Write-Host "  Bicep provisions infrastructure, then post-provision.ps1 installs AIO."
Write-Host ""

azd up --no-prompt
