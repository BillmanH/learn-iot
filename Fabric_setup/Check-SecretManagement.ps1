<#
.SYNOPSIS
    Diagnostic script to check Azure IoT Operations secret management configuration

.DESCRIPTION
    This script checks for managed identities, Key Vault configuration, and 
    CSI Secret Store setup to diagnose "Failed to fetch the secret provider" errors
    
.PARAMETER ResourceGroup
    Azure resource group name
    
.PARAMETER ClusterName
    Kubernetes cluster name

.EXAMPLE
    .\Check-SecretManagement.ps1 -ResourceGroup "my-rg" -ClusterName "iot-ops-cluster"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$ClusterName
)

# ============================================================================
# SCRIPT SETUP
# ============================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:ScriptDir "check_secret_management_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Start transcript logging
Start-Transcript -Path $script:LogFile -Append

# Color output functions
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

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ============================================================================
# AUTO-LOAD CONFIGURATION FROM FILES
# ============================================================================

function Find-ConfigFile {
    param([string]$FileName)
    
    $searchPaths = @(
        (Join-Path $PSScriptRoot $FileName),
        (Join-Path (Join-Path $PSScriptRoot "..") (Join-Path "linux_build" $FileName)),
        (Join-Path (Join-Path $PSScriptRoot "..") (Join-Path "linux_build" (Join-Path "edge_configs" $FileName))),
        (Join-Path (Get-Location) $FileName),
        (Join-Path (Join-Path (Get-Location) "linux_build") $FileName),
        (Join-Path (Join-Path (Get-Location) "edge_configs") $FileName)
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Load-ConfigurationFiles {
    Write-SubHeader "Loading Configuration Files"
    
    # Try to find cluster_info.json
    $clusterInfoPath = Find-ConfigFile "cluster_info.json"
    if ($clusterInfoPath) {
        Write-Success "Found cluster_info.json: $clusterInfoPath"
        try {
            $clusterInfo = Get-Content $clusterInfoPath -Raw | ConvertFrom-Json
            $script:ClusterName = $clusterInfo.cluster_name
            Write-Info "  Loaded cluster_name: $script:ClusterName"
        } catch {
            Write-Warning "Could not parse cluster_info.json: $_"
        }
    } else {
        Write-Warning "cluster_info.json not found in common locations"
    }
    
    # Try to find aio_config.json
    $aioConfigPath = Find-ConfigFile "aio_config.json"
    if ($aioConfigPath) {
        Write-Success "Found aio_config.json: $aioConfigPath"
        try {
            $aioConfig = Get-Content $aioConfigPath -Raw | ConvertFrom-Json
            $script:ResourceGroup = $aioConfig.azure.resource_group
            Write-Info "  Loaded resource_group: $script:ResourceGroup"
        } catch {
            Write-Warning "Could not parse aio_config.json: $_"
        }
    } else {
        Write-Warning "aio_config.json not found in common locations"
    }
}

# Load configuration files first
Load-ConfigurationFiles

# Get parameters if not provided (either from command line or config files)
if ([string]::IsNullOrEmpty($ResourceGroup)) {
    $ResourceGroup = Read-Host "Enter Resource Group name"
}

if ([string]::IsNullOrEmpty($ClusterName)) {
    $ClusterName = Read-Host "Enter Cluster name"
}

$aioInstanceName = "$ClusterName-aio"

Write-Header "Azure IoT Operations Secret Management Diagnostic"
Write-Info "Log file: $script:LogFile"
Write-Info "Started: $(Get-Date)"
Write-Info "Script directory: $script:ScriptDir"
Write-Info ""
Write-Info "Resource Group: $ResourceGroup"
Write-Info "Cluster Name: $ClusterName"
Write-Info "AIO Instance: $aioInstanceName"

# ============================================================================
# Check Azure CLI
# ============================================================================
Write-SubHeader "Checking Prerequisites"

try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-Error "Azure CLI not found or not configured"
    exit 1
}

try {
    kubectl version --client --output=json | Out-Null
    Write-Success "kubectl is available"
} catch {
    Write-Warning "kubectl not found - cluster checks will be skipped"
}

# ============================================================================
# Check Azure Arc Cluster Identity
# ============================================================================
Write-Header "Azure Arc Cluster Identity"

try {
    $arcCluster = az connectedk8s show --name $ClusterName --resource-group $ResourceGroup 2>&1 | ConvertFrom-Json
    
    if ($arcCluster.identity) {
        Write-Success "Arc cluster has managed identity"
        Write-Host "  Type: $($arcCluster.identity.type)" -ForegroundColor Gray
        Write-Host "  Principal ID: $($arcCluster.identity.principalId)" -ForegroundColor Gray
        Write-Host "  Tenant ID: $($arcCluster.identity.tenantId)" -ForegroundColor Gray
    } else {
        Write-Warning "Arc cluster has no managed identity"
        Write-Info "  To enable: az connectedk8s update --name $ClusterName --resource-group $ResourceGroup --enable-managed-identity"
    }
} catch {
    Write-Error "Could not retrieve Arc cluster information"
    Write-Info "  Error: $_"
}

# ============================================================================
# Check All Managed Identities in Resource Group
# ============================================================================
Write-Header "All Managed Identities in Resource Group"

try {
    $identities = az identity list --resource-group $ResourceGroup 2>&1 | ConvertFrom-Json
    
    if ($identities -and $identities.Count -gt 0) {
        Write-Success "Found $($identities.Count) managed identity(ies)"
        foreach ($identity in $identities) {
            Write-Host "`nName: $($identity.name)" -ForegroundColor White
            Write-Host "  Client ID: $($identity.clientId)" -ForegroundColor Gray
            Write-Host "  Principal ID: $($identity.principalId)" -ForegroundColor Gray
            Write-Host "  Location: $($identity.location)" -ForegroundColor Gray
        }
    } else {
        Write-Warning "No user-assigned managed identities found"
    }
} catch {
    Write-Warning "Could not list managed identities"
    Write-Info "  Error: $_"
}

# ============================================================================
# Check IoT Operations Instance Identity
# ============================================================================
Write-Header "Azure IoT Operations Instance Identity"

try {
    $aioInstance = az iot ops show --name $aioInstanceName --resource-group $ResourceGroup 2>&1 | ConvertFrom-Json
    
    Write-Success "Found AIO instance: $($aioInstance.name)"
    Write-Host "  Provisioning State: $($aioInstance.provisioningState)" -ForegroundColor Gray
    
    if ($aioInstance.identity) {
        Write-Success "AIO instance has managed identity"
        Write-Host "  Type: $($aioInstance.identity.type)" -ForegroundColor Gray
        if ($aioInstance.identity.principalId) {
            Write-Host "  Principal ID: $($aioInstance.identity.principalId)" -ForegroundColor Gray
        }
        if ($aioInstance.identity.tenantId) {
            Write-Host "  Tenant ID: $($aioInstance.identity.tenantId)" -ForegroundColor Gray
        }
    } else {
        Write-Warning "AIO instance has no managed identity configured"
    }
} catch {
    Write-Error "Could not retrieve AIO instance information"
    Write-Info "  Error: $_"
}

# ============================================================================
# Check Resources with Managed Identities
# ============================================================================
Write-Header "All Resources with Managed Identities"

try {
    $resources = az resource list --resource-group $ResourceGroup --query "[?identity!=null]" 2>&1 | ConvertFrom-Json
    
    if ($resources -and $resources.Count -gt 0) {
        Write-Success "Found $($resources.Count) resource(s) with managed identities"
        foreach ($resource in $resources) {
            Write-Host "`nName: $($resource.name)" -ForegroundColor White
            Write-Host "  Type: $($resource.type)" -ForegroundColor Gray
            Write-Host "  Identity Type: $($resource.identity.type)" -ForegroundColor Gray
            if ($resource.identity.principalId) {
                Write-Host "  Principal ID: $($resource.identity.principalId)" -ForegroundColor Gray
            }
        }
    } else {
        Write-Warning "No resources with managed identities found"
    }
} catch {
    Write-Warning "Could not list resources with identities"
    Write-Info "  Error: $_"
}

# ============================================================================
# Check Key Vaults in Resource Group
# ============================================================================
Write-Header "Key Vaults in Resource Group"

try {
    $keyVaults = az keyvault list --resource-group $ResourceGroup 2>&1 | ConvertFrom-Json
    
    if ($keyVaults -and $keyVaults.Count -gt 0) {
        Write-Success "Found $($keyVaults.Count) Key Vault(s)"
        foreach ($kv in $keyVaults) {
            Write-Host "`nName: $($kv.name)" -ForegroundColor White
            Write-Host "  Location: $($kv.location)" -ForegroundColor Gray
            Write-Host "  Vault URI: $($kv.properties.vaultUri)" -ForegroundColor Gray
            Write-Host "  RBAC Enabled: $($kv.properties.enableRbacAuthorization)" -ForegroundColor Gray
        }
    } else {
        Write-Warning "No Key Vaults found in resource group"
        Write-Info "  Secret management requires a Key Vault"
        Write-Info "  Create one: az keyvault create --name <vault-name> --resource-group $ResourceGroup --enable-rbac-authorization true"
    }
} catch {
    Write-Warning "Could not list Key Vaults"
    Write-Info "  Error: $_"
}

# ============================================================================
# Check Cluster Configuration (if kubectl available)
# ============================================================================
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    Write-Header "Cluster Configuration (Kubernetes)"
    
    # Check CSI driver
    Write-SubHeader "CSI Secret Store Driver"
    try {
        $csiDriver = kubectl get csidriver secrets-store.csi.k8s.io --ignore-not-found 2>&1
        if ($csiDriver) {
            Write-Success "CSI Secret Store driver is installed"
        } else {
            Write-Error "CSI Secret Store driver NOT found"
            Write-Info "  This is required for secret management"
        }
    } catch {
        Write-Warning "Could not check CSI driver: $_"
    }
    
    # Check CSI driver pods
    Write-SubHeader "CSI Driver Pods"
    try {
        kubectl get pods -n kube-system -l app.kubernetes.io/name=secrets-store-csi-driver 2>&1
    } catch {
        Write-Warning "Could not list CSI driver pods"
    }
    
    # Check Azure provider pods
    Write-SubHeader "Azure Key Vault Provider Pods"
    try {
        kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure 2>&1
    } catch {
        Write-Warning "Could not list Azure provider pods"
    }
    
    # Check SecretProviderClass
    Write-SubHeader "SecretProviderClass Resources"
    try {
        $spcList = kubectl get secretproviderclass -A 2>&1
        if ($spcList -match "No resources found") {
            Write-Warning "No SecretProviderClass resources found"
            Write-Info "  These are needed to connect to Key Vault"
        } else {
            Write-Success "SecretProviderClass resources found"
            kubectl get secretproviderclass -A
        }
    } catch {
        Write-Warning "Could not check SecretProviderClass resources"
    }
    
    # Check AIO broker configuration
    Write-SubHeader "AIO Broker Configuration"
    try {
        $brokers = kubectl get broker -n azure-iot-operations --no-headers 2>&1
        if ($brokers) {
            Write-Success "Found AIO broker(s)"
            kubectl get broker -n azure-iot-operations -o yaml | Select-String -Pattern "secret" -Context 2
        } else {
            Write-Warning "No AIO brokers found"
        }
    } catch {
        Write-Warning "Could not check AIO broker configuration"
    }
    
    # Check AIO pods
    Write-SubHeader "AIO Pods Status"
    try {
        kubectl get pods -n azure-iot-operations 2>&1
    } catch {
        Write-Warning "Could not list AIO pods"
    }
}

# ============================================================================
# Summary and Recommendations
# ============================================================================
Write-Header "Summary and Next Steps"

Write-Host "`nCommon causes of 'Failed to fetch the secret provider' error:" -ForegroundColor Yellow
Write-Host "  1. CSI Secret Store driver not installed on cluster" -ForegroundColor Gray
Write-Host "  2. No Key Vault created in the resource group" -ForegroundColor Gray
Write-Host "  3. Managed identity doesn't have Key Vault permissions" -ForegroundColor Gray
Write-Host "  4. No SecretProviderClass configured on cluster" -ForegroundColor Gray
Write-Host "  5. AIO instance not configured to use secret management" -ForegroundColor Gray

Write-Host "`nRecommended actions:" -ForegroundColor Green
Write-Host "  1. Ensure CSI Secret Store is installed (check linux_installer.sh)" -ForegroundColor Gray
Write-Host "  2. Create Key Vault if missing" -ForegroundColor Gray
Write-Host "  3. Grant 'Key Vault Secrets User' role to managed identity" -ForegroundColor Gray
Write-Host "  4. Create SecretProviderClass on cluster" -ForegroundColor Gray
Write-Host "  5. Configure AIO broker to use secret provider" -ForegroundColor Gray

Write-Host "Diagnostic completed: $(Get-Date)" -ForegroundColor Green
Write-Host "Log file: $script:LogFile" -ForegroundColor Gray
Write-Host "`n"

# Stop transcript
Stop-Transcript
Write-Host "`nFor detailed setup instructions, see:" -ForegroundColor Cyan
Write-Host "  linux_build\CSI_SECRET_STORE_SETUP.md" -ForegroundColor White

Write-Host "`n"
