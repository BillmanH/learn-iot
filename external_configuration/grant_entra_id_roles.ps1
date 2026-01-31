<#
.SYNOPSIS
    Grant Entra ID roles and permissions for Azure IoT Operations and Microsoft Fabric integration

.DESCRIPTION
    This script grants all necessary Entra ID roles, RBAC permissions, and Key Vault policies
    to enable Azure IoT Operations to communicate with Microsoft Fabric Real-Time Intelligence
    and grants user access to Key Vault and IoT resources.
    
.PARAMETER ResourceGroup
    Azure resource group name (default: from config/aio_config.json)
    
.PARAMETER ClusterName
    Kubernetes cluster name (default: from config/aio_config.json)
    
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
    
    $repoRoot = Split-Path -Parent $script:ScriptDir
    $configDir = Join-Path $repoRoot "config"
    
    $searchPaths = @(
        (Join-Path $configDir $FileName),
        (Join-Path $script:ScriptDir $FileName),
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
    
    # Try to load aio_config.json first (primary source for Azure configuration)
    $configPath = Find-ConfigFile "aio_config.json"
    if ($configPath) {
        Write-Success "Found aio_config.json: $configPath"
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $script:ResourceGroup = $config.azure.resource_group
            $script:SubscriptionId = $config.azure.subscription_id
            $script:ClusterName = $config.azure.cluster_name
            if ($config.azure.key_vault_name) {
                $script:KeyVaultName = $config.azure.key_vault_name
            }
            Write-Info "  Resource Group: $script:ResourceGroup"
            Write-Info "  Subscription: $script:SubscriptionId"
            Write-Info "  Cluster Name: $script:ClusterName"
        } catch {
            Write-Warning "Could not parse aio_config.json"
        }
    }
    
    # Try to load cluster_info.json to validate cluster name consistency
    $clusterInfoPath = Find-ConfigFile "cluster_info.json"
    if ($clusterInfoPath) {
        Write-Success "Found cluster_info.json: $clusterInfoPath"
        try {
            $clusterInfo = Get-Content $clusterInfoPath -Raw | ConvertFrom-Json
            $clusterInfoClusterName = $clusterInfo.cluster_name
            Write-Info "  Cluster (from edge): $clusterInfoClusterName"
            
            # Check for mismatch
            if ($script:ClusterName -and $clusterInfoClusterName -and ($script:ClusterName -ne $clusterInfoClusterName)) {
                Write-Host ""
                Write-Warning "CLUSTER NAME MISMATCH DETECTED!"
                Write-Host "  aio_config.json:    $script:ClusterName" -ForegroundColor Yellow
                Write-Host "  cluster_info.json:  $clusterInfoClusterName" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Using aio_config.json value for Azure RBAC operations." -ForegroundColor Cyan
                Write-Host "If this is wrong, update aio_config.json to match cluster_info.json." -ForegroundColor Gray
                Write-Host ""
            }
        } catch {
            Write-Warning "Could not parse cluster_info.json"
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
$keyVaultUsesRbac = $false
if ($script:KeyVaultName) {
    $keyVault = az keyvault show --name $script:KeyVaultName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
    
    if ($keyVault) {
        Write-Success "Key Vault: $script:KeyVaultName"
        Write-Info "  Resource ID: $($keyVault.id)"
        Write-Info "  Vault URI: $($keyVault.properties.vaultUri)"
        
        # Check if Key Vault uses RBAC or access policies
        $keyVaultUsesRbac = $keyVault.properties.enableRbacAuthorization -eq $true
        if ($keyVaultUsesRbac) {
            Write-Info "  Authorization: RBAC (Role-Based Access Control)"
        } else {
            Write-Info "  Authorization: Access Policies"
        }
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
# GRANT ROLES - KEY VAULT (RBAC or Access Policies)
# ============================================================================

if ($keyVaultUsesRbac) {
    Write-Header "Granting Key Vault Permissions (RBAC)"
} else {
    Write-Header "Granting Key Vault Permissions (Access Policies)"
}

if ($keyVault) {
    $kvName = $script:KeyVaultName
    $kvResourceId = $keyVault.id
    
    # Key Vault RBAC role IDs
    $kvSecretsUserRoleId = "4633458b-17de-408a-b874-0445c86b69e6"      # Key Vault Secrets User (read secrets)
    $kvSecretsOfficerRoleId = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"  # Key Vault Secrets Officer (full secrets access)
    $kvAdminRoleId = "00482a5a-887f-4fb3-b363-3b7fe8e74483"           # Key Vault Administrator (full access)
    
    # Grant to user - full admin access
    Write-SubHeader "User: $AddUser"
    
    if ($keyVaultUsesRbac) {
        Write-Info "Assigning Key Vault Administrator role to user..."
        az role assignment create `
            --role $kvAdminRoleId `
            --assignee-object-id $userObjectId `
            --assignee-principal-type User `
            --scope $kvResourceId `
            --output none 2>$null
        Write-Success "Granted Key Vault Administrator role to user"
    } else {
        Write-Info "Setting Key Vault access policy for user (get, list, set, delete secrets)..."
        az keyvault set-policy `
            --name $kvName `
            --object-id $userObjectId `
            --secret-permissions get list set delete backup restore recover purge `
            --key-permissions get list create delete backup restore recover purge `
            --certificate-permissions get list create delete backup restore recover purge `
            --output none 2>$null
        Write-Success "Granted full Key Vault access to user"
    }
    
    # Grant to Arc cluster identity - secrets read access
    if ($arcClusterIdentity.principalId) {
        Write-SubHeader "Arc Cluster Identity"
        
        if ($keyVaultUsesRbac) {
            Write-Info "Assigning Key Vault Secrets User role to Arc cluster..."
            az role assignment create `
                --role $kvSecretsUserRoleId `
                --assignee-object-id $arcClusterIdentity.principalId `
                --assignee-principal-type ServicePrincipal `
                --scope $kvResourceId `
                --output none 2>$null
            Write-Success "Granted Key Vault Secrets User role to Arc cluster"
        } else {
            Write-Info "Setting Key Vault access policy for Arc cluster (get, list secrets)..."
            az keyvault set-policy `
                --name $kvName `
                --object-id $arcClusterIdentity.principalId `
                --secret-permissions get list `
                --output none 2>$null
            Write-Success "Granted Key Vault secrets access to Arc cluster"
        }
    }
    
    # Grant to AIO instance identity - secrets read access
    if ($aioIdentity.principalId) {
        Write-SubHeader "AIO Instance Identity"
        
        if ($keyVaultUsesRbac) {
            Write-Info "Assigning Key Vault Secrets User role to AIO instance..."
            az role assignment create `
                --role $kvSecretsUserRoleId `
                --assignee-object-id $aioIdentity.principalId `
                --assignee-principal-type ServicePrincipal `
                --scope $kvResourceId `
                --output none 2>$null
            Write-Success "Granted Key Vault Secrets User role to AIO instance"
        } else {
            Write-Info "Setting Key Vault access policy for AIO instance (get, list secrets)..."
            az keyvault set-policy `
                --name $kvName `
                --object-id $aioIdentity.principalId `
                --secret-permissions get list `
                --output none 2>$null
            Write-Success "Granted Key Vault secrets access to AIO instance"
        }
    }
    
    # Grant to all managed identities - secrets read access
    if ($managedIdentities -and $managedIdentities.Count -gt 0) {
        Write-SubHeader "All Managed Identities"
        
        foreach ($identity in $managedIdentities) {
            if ($keyVaultUsesRbac) {
                Write-Info "Assigning Key Vault Secrets User role to: $($identity.name)..."
                az role assignment create `
                    --role $kvSecretsUserRoleId `
                    --assignee-object-id $identity.principalId `
                    --assignee-principal-type ServicePrincipal `
                    --scope $kvResourceId `
                    --output none 2>$null
                Write-Success "  Granted Key Vault Secrets User role to: $($identity.name)"
            } else {
                Write-Info "Setting Key Vault access policy for: $($identity.name) (get, list secrets)..."
                az keyvault set-policy `
                    --name $kvName `
                    --object-id $identity.principalId `
                    --secret-permissions get list `
                    --output none 2>$null
                Write-Success "  Granted to: $($identity.name)"
            }
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
    
    # Azure Arc Kubernetes Cluster Admin - Required for kubectl access via az connectedk8s proxy
    Write-Info "Granting 'Azure Arc Kubernetes Cluster Admin' (required for kubectl proxy access)..."
    az role assignment create `
        --role "Azure Arc Kubernetes Cluster Admin" `
        --assignee $userObjectId `
        --scope $arcCluster.id `
        --output none 2>$null
    Write-Success "Granted Arc Kubernetes Cluster Admin"
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

# Check if Contributor at subscription level is needed
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Yellow
Write-Host "OPTIONAL: Subscription-Level Contributor Role" -ForegroundColor Yellow
Write-Host "============================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "The 'Contributor' role at subscription level allows:" -ForegroundColor Cyan
Write-Host "  - Creating new resource groups" -ForegroundColor Gray
Write-Host "  - Deploying ARM templates at subscription scope" -ForegroundColor Gray
Write-Host "  - Full resource management across all resource groups" -ForegroundColor Gray
Write-Host ""
Write-Host "This is a BROAD permission. Only grant if necessary." -ForegroundColor Yellow
Write-Host ""

$grantContributor = Read-Host "Grant 'Contributor' role at subscription level? (y/N)"

if ($grantContributor -eq 'y' -or $grantContributor -eq 'Y') {
    Write-Info "Granting 'Contributor' role at subscription level..."
    az role assignment create `
        --role "Contributor" `
        --assignee $userObjectId `
        --scope $subscriptionScope `
        --output none 2>$null
    Write-Success "Granted Contributor at subscription level"
} else {
    Write-Host ""
    Write-Host "Skipping Contributor role at subscription level." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "ALTERNATIVE: If you need to create a resource group, run this manually:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  az group create --name $script:ResourceGroup --location eastus" -ForegroundColor Green
    Write-Host ""
    Write-Host "Or ask your Azure admin to create the resource group for you." -ForegroundColor Gray
    Write-Host "Once the resource group exists, External-Configurator.ps1 will skip creation." -ForegroundColor Gray
    Write-Host ""
}

# ============================================================================
# GRANT ROLES - ROLE ASSIGNMENT PERMISSIONS
# ============================================================================

Write-Header "Role Assignment Permissions (for External-Configurator.ps1)"

Write-SubHeader "User: $AddUser"

# This role allows the user to create role assignments within the resource group
# Required by External-Configurator.ps1 to assign Storage Blob Data Contributor to Schema Registry
Write-Info "Granting 'Role Based Access Control Administrator' on resource group..."
az role assignment create `
    --role "Role Based Access Control Administrator" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Role Based Access Control Administrator"

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

# Pre-grant Storage Blob Data Contributor to any existing schema registries
# This is also done by External-Configurator.ps1, but we do it here proactively
Write-SubHeader "Schema Registry Storage Access"
$schemaRegistries = az resource list --resource-group $script:ResourceGroup --resource-type "Microsoft.DeviceRegistry/schemaRegistries" --query "[].name" -o tsv 2>$null
if ($schemaRegistries) {
    foreach ($srName in $schemaRegistries -split "`n") {
        if ($srName) {
            Write-Info "Found schema registry: $srName"
            $srPrincipalId = az resource show `
                --resource-group $script:ResourceGroup `
                --resource-type "Microsoft.DeviceRegistry/schemaRegistries" `
                --name $srName `
                --query "identity.principalId" -o tsv 2>$null
            
            if ($srPrincipalId) {
                Write-Info "Granting 'Storage Blob Data Contributor' to schema registry..."
                az role assignment create `
                    --role "Storage Blob Data Contributor" `
                    --assignee $srPrincipalId `
                    --scope $rgScope `
                    --output none 2>$null
                Write-Success "Granted Storage Blob Data Contributor to: $srName"
            }
        }
    }
} else {
    Write-Info "No schema registries found yet (will be created by External-Configurator.ps1)"
}

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
Write-Success "Key Vault Permissions (Access Policies):"
if ($keyVault) {
    Write-Info "  [OK] User '$AddUser': Full access (get, list, set, delete secrets/keys/certs)"
    Write-Info "  [OK] Arc Cluster: Secrets read access (get, list)"
    Write-Info "  [OK] AIO Instance: Secrets read access (get, list)"
    Write-Info "  [OK] All Managed Identities: Secrets read access (get, list)"
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
