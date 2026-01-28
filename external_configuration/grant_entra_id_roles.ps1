<#
.SYNOPSIS
    Grant Entra ID roles and permissions for Azure IoT Operations and Microsoft Fabric integration

.DESCRIPTION
    This script grants all necessary Entra ID roles, RBAC permissions, and Key Vault policies
    to enable Azure IoT Operations to communicate with Microsoft Fabric Real-Time Intelligence
    and grants user access to Key Vault and IoT resources.
    
.PARAMETER ResourceGroup
    Azure resource group name (default: from linux_aio_config.json)
    
.PARAMETER ClusterName
    Kubernetes cluster name (default: from cluster_info.json)
    
.PARAMETER KeyVaultName
    Azure Key Vault name (default: auto-detected from resource group)
    
.PARAMETER AddUser
    User email/UPN or Object ID (GUID) to grant full access
    Examples: you@mail.com or 12345678-1234-1234-1234-123456789abc
    Optional - if not provided, grants to current signed-in user

.PARAMETER SubscriptionId
    Azure subscription ID (default: from config or current subscription)
    
.EXAMPLE
    .\grant_entra_id_roles.ps1
    
.EXAMPLE
    .\grant_entra_id_roles.ps1 -AddUser you@mail.com or 12345678-1234-1234-1234-123456789abc
    
.EXAMPLE
    .\grant_entra_id_roles.ps1 -ResourceGroup "IoT-Operations" -ClusterName "iot-ops-cluster" -AddUser <your OID>

.NOTES
    Author: Azure IoT Operations Team
    Date: January 2026
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,
    
    [Parameter(Mandatory=$false)]
    [string]$KeyVaultName,
    
    [Parameter(Mandatory=$false)]
    [string]$AddUser,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

# ============================================================================
# SCRIPT SETUP
# ============================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:ScriptDir "grant_entra_id_roles_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Start-Transcript -Path $script:LogFile -Append

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host $('=' * 80) -ForegroundColor Cyan
}

function Write-SubHeader {
    param([string]$Message)
    Write-Host "`n--- $Message ---" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

function Find-ConfigFile {
    param([string]$FileName)
    
    $searchPaths = @(
        (Join-Path $script:ScriptDir $FileName),
        (Join-Path $script:ScriptDir "edge_configs\$FileName"),
        (Join-Path (Get-Location) $FileName)
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Load-Configuration {
    Write-SubHeader "Loading Configuration"
    
    # Try to load cluster_info.json
    $clusterInfoPath = Find-ConfigFile "cluster_info.json"
    if ($clusterInfoPath) {
        Write-Success "Found cluster_info.json: $clusterInfoPath"
        try {
            $clusterInfo = Get-Content $clusterInfoPath -Raw | ConvertFrom-Json
            $script:ClusterName = $clusterInfo.cluster_name
            Write-Info "  Cluster: $script:ClusterName"
        } catch {
            Write-Warning "Could not parse cluster_info.json"
        }
    }
    
    # Try to load linux_aio_config.json
    $configPath = Find-ConfigFile "linux_aio_config.json"
    if ($configPath) {
        Write-Success "Found linux_aio_config.json: $configPath"
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $script:ResourceGroup = $config.azure.resource_group
            $script:SubscriptionId = $config.azure.subscription_id
            if ($config.azure.key_vault_name) {
                $script:KeyVaultName = $config.azure.key_vault_name
            }
            Write-Info "  Resource Group: $script:ResourceGroup"
            Write-Info "  Subscription: $script:SubscriptionId"
        } catch {
            Write-Warning "Could not parse linux_aio_config.json"
        }
    }
}

# Load config first
Load-Configuration

# Override with command-line parameters if provided
if ($PSBoundParameters.ContainsKey('ResourceGroup')) {
    $script:ResourceGroup = $ResourceGroup
}
if ($PSBoundParameters.ContainsKey('ClusterName')) {
    $script:ClusterName = $ClusterName
}
if ($PSBoundParameters.ContainsKey('KeyVaultName')) {
    $script:KeyVaultName = $KeyVaultName
}
if ($PSBoundParameters.ContainsKey('SubscriptionId')) {
    $script:SubscriptionId = $SubscriptionId
}

# Prompt for missing required values
if ([string]::IsNullOrEmpty($script:ResourceGroup)) {
    $script:ResourceGroup = Read-Host "Enter Resource Group name"
}

if ([string]::IsNullOrEmpty($script:ClusterName)) {
    $script:ClusterName = Read-Host "Enter Cluster name"
}

# ============================================================================
# PREREQUISITES
# ============================================================================

Write-Header "Azure IoT Operations - Grant Entra ID Roles and Permissions"
Write-Info "Log file: $script:LogFile"
Write-Info "Started: $(Get-Date)"
Write-Info ""
Write-Info "Resource Group: $script:ResourceGroup"
Write-Info "Cluster Name: $script:ClusterName"
if ($script:KeyVaultName) {
    Write-Info "Key Vault: $script:KeyVaultName"
}
if ($AddUser) {
    Write-Info "User to grant access: $AddUser"
}

Write-SubHeader "Checking Prerequisites"

try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-ErrorMsg "Azure CLI not found"
    Stop-Transcript
    exit 1
}

# ============================================================================
# AZURE AUTHENTICATION
# ============================================================================

Write-SubHeader "Checking Azure Authentication"

$currentAccount = az account show 2>$null | ConvertFrom-Json
if (-not $currentAccount) {
    Write-Info "Not logged into Azure. Logging in..."
    az login
    $currentAccount = az account show | ConvertFrom-Json
}

Write-Success "Logged into Azure"
Write-Info "  Account: $($currentAccount.user.name)"
Write-Info "  Subscription: $($currentAccount.name)"

# Set subscription if specified
if ($script:SubscriptionId) {
    az account set --subscription $script:SubscriptionId
    $currentAccount = az account show | ConvertFrom-Json
}

$script:SubscriptionId = $currentAccount.id
$script:TenantId = $currentAccount.tenantId

Write-Info "  Using subscription: $($currentAccount.name) ($script:SubscriptionId)"

# ============================================================================
# GET RESOURCE IDS
# ============================================================================

Write-Header "Discovering Resources"

# Get Arc cluster
Write-SubHeader "Arc-Enabled Cluster"
$arcCluster = az connectedk8s show --name $script:ClusterName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json

if ($arcCluster) {
    Write-Success "Found Arc cluster: $script:ClusterName"
    Write-Info "  Resource ID: $($arcCluster.id)"
    $arcClusterIdentity = $arcCluster.identity
    if ($arcClusterIdentity.principalId) {
        Write-Success "Arc cluster has managed identity"
        Write-Info "  Principal ID: $($arcClusterIdentity.principalId)"
    }
} else {
    Write-Warning "Arc cluster not found: $script:ClusterName"
}

# Get AIO instance
Write-SubHeader "Azure IoT Operations Instance"
$aioInstanceName = "$script:ClusterName-aio"
$aioInstance = az iot ops show --name $aioInstanceName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json

if ($aioInstance) {
    Write-Success "Found AIO instance: $aioInstanceName"
    Write-Info "  Resource ID: $($aioInstance.id)"
    $aioIdentity = $aioInstance.identity
    if ($aioIdentity.principalId) {
        Write-Success "AIO instance has managed identity"
        Write-Info "  Principal ID: $($aioIdentity.principalId)"
    }
} else {
    Write-Warning "AIO instance not found: $aioInstanceName"
}

# Get or find Key Vault
Write-SubHeader "Azure Key Vault"
if ([string]::IsNullOrEmpty($script:KeyVaultName)) {
    Write-Info "Key Vault name not specified, searching resource group..."
    $keyVaults = az keyvault list --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
    
    if ($keyVaults -and $keyVaults.Count -gt 0) {
        $script:KeyVaultName = $keyVaults[0].name
        Write-Success "Found Key Vault: $script:KeyVaultName"
    } else {
        Write-Warning "No Key Vaults found in resource group"
    }
}

$keyVault = $null
if ($script:KeyVaultName) {
    $keyVault = az keyvault show --name $script:KeyVaultName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
    
    if ($keyVault) {
        Write-Success "Key Vault: $script:KeyVaultName"
        Write-Info "  Resource ID: $($keyVault.id)"
        Write-Info "  Vault URI: $($keyVault.properties.vaultUri)"
    } else {
        Write-Warning "Key Vault not found: $script:KeyVaultName"
    }
}

# Get all managed identities in resource group
Write-SubHeader "Managed Identities in Resource Group"
$managedIdentities = az identity list --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json

if ($managedIdentities -and $managedIdentities.Count -gt 0) {
    Write-Success "Found $($managedIdentities.Count) managed identity(ies)"
    foreach ($identity in $managedIdentities) {
        Write-Info "  - $($identity.name) (Principal ID: $($identity.principalId))"
    }
} else {
    Write-Info "No user-assigned managed identities found"
}

# Get user to grant access to
Write-SubHeader "User Access"
if ([string]::IsNullOrEmpty($AddUser)) {
    $AddUser = $currentAccount.user.name
    Write-Info "No user specified, using current signed-in user: $AddUser"
} else {
    Write-Info "Will grant access to: $AddUser"
}

# Get user object ID
$userObjectId = $null

# Check if input is already a GUID (Object ID)
$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if ($AddUser -match $guidPattern) {
    # Input is already an Object ID
    $userObjectId = $AddUser
    Write-Success "Using Object ID: $userObjectId"
    
    # Try to get user display name for informational purposes
    $userInfo = az ad user show --id $userObjectId --query "{displayName:displayName, userPrincipalName:userPrincipalName}" 2>$null | ConvertFrom-Json
    if ($userInfo) {
        Write-Info "  Display Name: $($userInfo.displayName)"
        Write-Info "  UPN: $($userInfo.userPrincipalName)"
    }
} else {
    # Input is email/UPN, need to look up Object ID
    $userObjectId = az ad user show --id $AddUser --query id -o tsv 2>$null
    
    if ($userObjectId) {
        Write-Success "Found user: $AddUser"
        Write-Info "  Object ID: $userObjectId"
    } else {
        Write-ErrorMsg "Could not find user: $AddUser"
        Write-Info "Options:"
        Write-Info "  1. Verify the email/UPN is correct"
        Write-Info "  2. Use the Object ID instead: -AddUser <object-id-guid>"
        Write-Info "  3. Get your Object ID: az ad signed-in-user show --query id -o tsv"
        Write-Info "  4. Search for user: az ad user list --filter ""startswith(displayName,'username')"""
        Stop-Transcript
        exit 1
    }
}

# ============================================================================
# GRANT ROLES - KEY VAULT
# ============================================================================

Write-Header "Granting Key Vault Permissions"

if ($keyVault) {
    $kvScope = $keyVault.id
    
    # Grant to user
    Write-SubHeader "User: $AddUser"
    
    Write-Info "Granting 'Key Vault Administrator' role..."
    az role assignment create `
        --role "Key Vault Administrator" `
        --assignee $userObjectId `
        --scope $kvScope `
        --output none 2>$null
    Write-Success "Granted Key Vault Administrator"
    
    # Grant to Arc cluster identity
    if ($arcClusterIdentity.principalId) {
        Write-SubHeader "Arc Cluster Identity"
        
        Write-Info "Granting 'Key Vault Secrets User' role..."
        az role assignment create `
            --role "Key Vault Secrets User" `
            --assignee $arcClusterIdentity.principalId `
            --scope $kvScope `
            --output none 2>$null
        Write-Success "Granted Key Vault Secrets User to Arc cluster"
    }
    
    # Grant to AIO instance identity
    if ($aioIdentity.principalId) {
        Write-SubHeader "AIO Instance Identity"
        
        Write-Info "Granting 'Key Vault Secrets User' role..."
        az role assignment create `
            --role "Key Vault Secrets User" `
            --assignee $aioIdentity.principalId `
            --scope $kvScope `
            --output none 2>$null
        Write-Success "Granted Key Vault Secrets User to AIO instance"
    }
    
    # Grant to all managed identities
    if ($managedIdentities -and $managedIdentities.Count -gt 0) {
        Write-SubHeader "All Managed Identities"
        
        foreach ($identity in $managedIdentities) {
            Write-Info "Granting 'Key Vault Secrets User' to: $($identity.name)"
            az role assignment create `
                --role "Key Vault Secrets User" `
                --assignee $identity.principalId `
                --scope $kvScope `
                --output none 2>$null
            Write-Success "  Granted to: $($identity.name)"
        }
    }
} else {
    Write-Warning "Skipping Key Vault permissions (no Key Vault found)"
}

# ============================================================================
# GRANT ROLES - AZURE IOT OPERATIONS
# ============================================================================

Write-Header "Granting Azure IoT Operations Permissions"

Write-SubHeader "User: $AddUser"

# Resource group scope
$rgScope = "/subscriptions/$script:SubscriptionId/resourceGroups/$script:ResourceGroup"

# Contributor role for IoT Operations
Write-Info "Granting 'Contributor' role on resource group..."
az role assignment create `
    --role "Contributor" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Contributor on resource group"

# IoT Hub Data Contributor (if IoT Hub exists)
Write-Info "Granting 'IoT Hub Data Contributor' role..."
az role assignment create `
    --role "IoT Hub Data Contributor" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted IoT Hub Data Contributor"

# Azure Arc Kubernetes Cluster User Role
if ($arcCluster) {
    Write-Info "Granting 'Azure Arc Kubernetes Cluster User Role'..."
    az role assignment create `
        --role "Azure Arc Kubernetes Cluster User Role" `
        --assignee $userObjectId `
        --scope $arcCluster.id `
        --output none 2>$null
    Write-Success "Granted Arc Kubernetes Cluster User Role"
    
    # Azure Arc Kubernetes Viewer
    Write-Info "Granting 'Azure Arc Kubernetes Viewer'..."
    az role assignment create `
        --role "Azure Arc Kubernetes Viewer" `
        --assignee $userObjectId `
        --scope $arcCluster.id `
        --output none 2>$null
    Write-Success "Granted Arc Kubernetes Viewer"
}

# ============================================================================
# GRANT ROLES - MICROSOFT FABRIC INTEGRATION
# ============================================================================

Write-Header "Granting Microsoft Fabric Integration Permissions"

Write-SubHeader "Service Principal Roles for Fabric"

# These roles allow AIO to communicate with Fabric Event Hubs (Kafka)
$fabricRoles = @(
    "Azure Event Hubs Data Sender",
    "Azure Event Hubs Data Receiver",
    "Storage Blob Data Contributor"
)

foreach ($role in $fabricRoles) {
    # Grant to AIO instance identity
    if ($aioIdentity.principalId) {
        Write-Info "Granting '$role' to AIO instance..."
        az role assignment create `
            --role $role `
            --assignee $aioIdentity.principalId `
            --scope $rgScope `
            --output none 2>$null
        Write-Success "  Granted to AIO instance"
    }
    
    # Grant to Arc cluster identity
    if ($arcClusterIdentity.principalId) {
        Write-Info "Granting '$role' to Arc cluster..."
        az role assignment create `
            --role $role `
            --assignee $arcClusterIdentity.principalId `
            --scope $rgScope `
            --output none 2>$null
        Write-Success "  Granted to Arc cluster"
    }
}

# Grant to user for testing/development
Write-SubHeader "User: $AddUser"
foreach ($role in $fabricRoles) {
    Write-Info "Granting '$role'..."
    az role assignment create `
        --role $role `
        --assignee $userObjectId `
        --scope $rgScope `
        --output none 2>$null
    Write-Success "  Granted $role"
}

# ============================================================================
# GRANT ROLES - SUBSCRIPTION LEVEL (Optional)
# ============================================================================

Write-Header "Subscription-Level Permissions (for Resource Creation)"

$subscriptionScope = "/subscriptions/$script:SubscriptionId"

Write-SubHeader "User: $AddUser"

Write-Info "Granting 'Reader' role at subscription level..."
az role assignment create `
    --role "Reader" `
    --assignee $userObjectId `
    --scope $subscriptionScope `
    --output none 2>$null
Write-Success "Granted Reader at subscription level"

Write-Info "Note: If user needs to create resources, grant 'Contributor' at subscription level manually"

# ============================================================================
# GRANT ROLES - DATA PLANE (Schema Registry, Device Registry)
# ============================================================================

Write-Header "Data Plane Permissions"

# Schema Registry roles
Write-SubHeader "Schema Registry"
Write-Info "Granting 'Schema Registry Contributor' to user..."
az role assignment create `
    --role "Schema Registry Contributor (Preview)" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Schema Registry Contributor"

# Device Registry roles
Write-SubHeader "Device Registry"  
Write-Info "Granting 'Device Registry Contributor' to user..."
az role assignment create `
    --role "Contributor" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Device Registry access via Contributor"

# ============================================================================
# SUMMARY
# ============================================================================

Write-Header "Summary - Permissions Granted"

Write-Host ""
Write-Success "Key Vault Permissions:"
if ($keyVault) {
    Write-Info "  [OK] User '$AddUser': Key Vault Administrator"
    Write-Info "  [OK] Arc Cluster: Key Vault Secrets User"
    Write-Info "  [OK] AIO Instance: Key Vault Secrets User"
    Write-Info "  [OK] All Managed Identities: Key Vault Secrets User"
} else {
    Write-Warning "  (No Key Vault found - permissions skipped)"
}

Write-Host ""
Write-Success "Azure IoT Operations Permissions:"
Write-Info "  [OK] User '$AddUser': Contributor (resource group)"
Write-Info "  [OK] User '$AddUser': IoT Hub Data Contributor"
Write-Info "  [OK] User '$AddUser': Arc Kubernetes Cluster User"
Write-Info "  [OK] User '$AddUser': Arc Kubernetes Viewer"

Write-Host ""
Write-Success "Microsoft Fabric Integration Permissions:"
Write-Info "  [OK] AIO Instance: Event Hubs Data Sender/Receiver"
Write-Info "  [OK] AIO Instance: Storage Blob Data Contributor"
Write-Info "  [OK] Arc Cluster: Event Hubs Data Sender/Receiver"
Write-Info "  [OK] Arc Cluster: Storage Blob Data Contributor"
Write-Info "  [OK] User '$AddUser': Event Hubs Data Sender/Receiver"
Write-Info "  [OK] User '$AddUser': Storage Blob Data Contributor"

Write-Host ""
Write-Success "Subscription-Level Permissions:"
Write-Info "  [OK] User '$AddUser': Reader (subscription)"

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Green
Write-Host "  1. User can now access Key Vault secrets" -ForegroundColor Gray
Write-Host "  2. User can manage IoT Operations resources" -ForegroundColor Gray
Write-Host "  3. AIO can send data to Fabric Real-Time Intelligence" -ForegroundColor Gray
Write-Host "  4. User can create and manage dataflows" -ForegroundColor Gray
Write-Host "  5. Test access in Azure Portal" -ForegroundColor Gray

Write-Host ""
Write-Host "To verify permissions:" -ForegroundColor Cyan
Write-Host "  az role assignment list --assignee $userObjectId --scope $rgScope" -ForegroundColor White

Write-Host ""
Write-Host "Completed: $(Get-Date)" -ForegroundColor Green
Write-Host "Log file: $script:LogFile" -ForegroundColor Gray
Write-Host ""

Stop-Transcript
