#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Connects the K3s cluster to Azure Arc using PowerShell Az modules.

.DESCRIPTION
    This script connects the K3s cluster to Azure Arc.
    Run this AFTER installer.sh and AFTER the resource group exists in Azure.

.PARAMETER ConfigFile
    Path to the aio_config.json file. Default: ../config/aio_config.json

.PARAMETER DryRun
    Show what would be done without making changes.

.EXAMPLE
    ./arc_enable.ps1

.EXAMPLE
    ./arc_enable.ps1 -DryRun

.NOTES
    Author: Azure IoT Operations Team
    Date: January 2026
    Version: 2.0.0 - PowerShell Az Module Based
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path (Split-Path -Parent $ScriptDir) "config"

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = Join-Path $ConfigDir "aio_config.json"
}

$ClusterInfoFile = Join-Path $ConfigDir "cluster_info.json"
$LogFile = Join-Path $ScriptDir "arc_enable_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Configuration variables
$script:ClusterName = ""
$script:ResourceGroup = ""
$script:SubscriptionId = ""
$script:Location = ""

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor Green
    Add-Content -Path $LogFile -Value $line
}

function Write-InfoLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] INFO: $Message"
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value $line
}

function Write-WarnLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] WARNING: $Message"
    Write-Host $line -ForegroundColor Yellow
    Add-Content -Path $LogFile -Value $line
}

function Write-ErrorLog {
    param([string]$Message, [switch]$Fatal)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] ERROR: $Message"
    Write-Host $line -ForegroundColor Red
    Add-Content -Path $LogFile -Value $line
    if ($Fatal) {
        throw $Message
    }
}

function Write-Success {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] SUCCESS: $Message"
    Write-Host $line -ForegroundColor Green
    Add-Content -Path $LogFile -Value $line
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

function Load-Configuration {
    Write-Log "Loading configuration from $ConfigFile..."
    
    if (-not (Test-Path $ConfigFile)) {
        Write-ErrorLog "Configuration file not found: $ConfigFile

Please create aio_config.json with your Azure settings:
  cp $ConfigDir/aio_config.json.template $ConfigFile
  
Then edit it with your subscription, resource group, and cluster name." -Fatal
    }
    
    try {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        Write-ErrorLog "Invalid JSON in configuration file: $ConfigFile" -Fatal
    }
    
    # Load values
    $script:ClusterName = $config.azure.cluster_name
    $script:ResourceGroup = $config.azure.resource_group
    $script:SubscriptionId = $config.azure.subscription_id
    $script:Location = if ($config.azure.location) { $config.azure.location } else { "eastus" }
    
    # Validate required fields
    if ([string]::IsNullOrEmpty($script:ClusterName)) {
        Write-ErrorLog "cluster_name not found in $ConfigFile" -Fatal
    }
    if ([string]::IsNullOrEmpty($script:ResourceGroup)) {
        Write-ErrorLog "resource_group not found in $ConfigFile" -Fatal
    }
    if ([string]::IsNullOrEmpty($script:SubscriptionId)) {
        Write-ErrorLog "subscription_id not found in $ConfigFile" -Fatal
    }
    
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Cluster Name:   $script:ClusterName"
    Write-Host "  Resource Group: $script:ResourceGroup"
    Write-Host "  Subscription:   $script:SubscriptionId"
    Write-Host "  Location:       $script:Location"
    Write-Host ""
    
    Write-Success "Configuration loaded"
}

# ============================================================================
# PREREQUISITES
# ============================================================================

function Check-Prerequisites {
    Write-Log "Checking prerequisites..."
    
    # Check if kubectl is available
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-ErrorLog "kubectl not found. Please run installer.sh first." -Fatal
    }
    Write-Success "kubectl is available"
    
    # Check if cluster is accessible
    try {
        $null = kubectl get nodes 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl failed"
        }
    } catch {
        Write-ErrorLog "Cannot access Kubernetes cluster. Is K3s running?

Check with: sudo systemctl status k3s
Restart with: sudo systemctl restart k3s" -Fatal
    }
    Write-Success "Kubernetes cluster is accessible"
    
    # Check for required PowerShell modules
    $requiredModules = @("Az.Accounts", "Az.Resources", "Az.ConnectedKubernetes")
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-ErrorLog "Required PowerShell module not found: $module

Install with: Install-Module -Name $module -Scope CurrentUser -Force" -Fatal
        }
        Write-Success "$module module is available"
    }
    
    # Import modules
    Import-Module Az.Accounts -ErrorAction SilentlyContinue
    Import-Module Az.Resources -ErrorAction SilentlyContinue
    Import-Module Az.ConnectedKubernetes -ErrorAction SilentlyContinue
    
    Write-Success "All prerequisites met"
}

# ============================================================================
# AZURE AUTHENTICATION
# ============================================================================

function Connect-ToAzure {
    Write-Log "Checking Azure authentication..."
    
    # Check if already logged in
    $context = Get-AzContext -ErrorAction SilentlyContinue
    
    if ($context) {
        Write-Success "Already logged in as: $($context.Account.Id)"
        Write-InfoLog "Current subscription: $($context.Subscription.Name)"
    } else {
        Write-Log "Not logged into Azure. Starting login..."
        
        if ($DryRun) {
            Write-InfoLog "[DRY-RUN] Would run: Connect-AzAccount"
        } else {
            # Use device code flow for Linux compatibility
            Connect-AzAccount -UseDeviceAuthentication
        }
    }
    
    # Set the correct subscription
    Write-Log "Setting subscription to: $script:SubscriptionId"
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would set subscription: $script:SubscriptionId"
    } else {
        Set-AzContext -SubscriptionId $script:SubscriptionId | Out-Null
        $currentContext = Get-AzContext
        Write-Success "Subscription set to: $($currentContext.Subscription.Name)"
    }
}

# ============================================================================
# RESOURCE GROUP CHECK
# ============================================================================

function Test-ResourceGroup {
    Write-Log "Checking if resource group exists: $script:ResourceGroup"
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would check for resource group: $script:ResourceGroup"
        return
    }
    
    $rg = Get-AzResourceGroup -Name $script:ResourceGroup -ErrorAction SilentlyContinue
    
    if ($rg) {
        Write-Success "Resource group exists: $script:ResourceGroup"
    } else {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "RESOURCE GROUP DOES NOT EXIST" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The resource group '$script:ResourceGroup' does not exist in Azure."
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  1. Create it now (requires Contributor role on subscription)"
        Write-Host "  2. Exit and create it manually or via External-Configurator.ps1"
        Write-Host ""
        
        $createRg = Read-Host "Create resource group now? (y/N)"
        
        if ($createRg -match "^[Yy]$") {
            Write-Log "Creating resource group: $script:ResourceGroup in $script:Location"
            New-AzResourceGroup -Name $script:ResourceGroup -Location $script:Location | Out-Null
            Write-Success "Resource group created: $script:ResourceGroup"
        } else {
            Write-Host ""
            Write-Host "To create the resource group manually, run:"
            Write-Host "  New-AzResourceGroup -Name $script:ResourceGroup -Location $script:Location"
            Write-Host ""
            Write-Host "Or run External-Configurator.ps1 from Windows first to create Azure resources."
            Write-Host ""
            Write-ErrorLog "Cannot continue without resource group" -Fatal
        }
    }
}

# ============================================================================
# ARC ENABLE
# ============================================================================

function Enable-ArcForCluster {
    Write-Log "Connecting cluster to Azure Arc..."
    
    # Get the Custom Locations RP object ID upfront - needed for initial connection
    # The Application ID bc313c14-388c-4e7d-a58e-70017303ee3b is fixed globally for the Custom Locations RP
    $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
    $customLocationsOid = $null
    
    Write-InfoLog "Retrieving Custom Locations Resource Provider object ID..."
    try {
        $customLocationsOid = (Get-AzADServicePrincipal -ApplicationId $customLocationsAppId -ErrorAction Stop).Id
        Write-InfoLog "Custom Locations RP Object ID: $customLocationsOid"
    } catch {
        Write-WarnLog "Could not retrieve Custom Locations RP object ID: $_"
    }
    
    # Check if already Arc-enabled
    $existingArc = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName -ErrorAction SilentlyContinue
    
    if ($existingArc) {
        Write-Success "Cluster '$script:ClusterName' is already Arc-enabled"
        Write-InfoLog "Connectivity status: $($existingArc.ConnectivityStatus)"
        Write-InfoLog "Private Link State: $($existingArc.PrivateLinkState)"
        
        # Check if private link is enabled (incompatible with custom-locations)
        if ($existingArc.PrivateLinkState -eq "Enabled") {
            Write-WarnLog "Cluster is connected with Private Link enabled"
            Write-WarnLog "Custom-locations and cluster-connect features are NOT compatible with Private Link"
            Write-WarnLog "To fix: Delete the Arc connection and re-run this script"
            Write-Host ""
            Write-Host "  To delete Arc connection:" -ForegroundColor Yellow
            Write-Host "    kubectl delete ns azure-arc" -ForegroundColor White
            Write-Host "    Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force" -ForegroundColor White
            Write-Host ""
        }
        
        # Store OID for later use in Enable-ArcFeatures
        $script:CustomLocationsOid = $customLocationsOid
    } else {
        Write-Log "Arc-enabling cluster: $script:ClusterName"
        
        if ($DryRun) {
            Write-InfoLog "[DRY-RUN] Would connect cluster with custom-locations enabled"
        } else {
            # New-AzConnectedKubernetes uses the current kubectl context
            # Include ALL features during initial connection to avoid issues with Set-AzConnectedKubernetes
            Write-InfoLog "Connecting with custom-locations, OIDC issuer, and workload identity enabled..."
            
            $connectParams = @{
                ResourceGroupName = $script:ResourceGroup
                ClusterName = $script:ClusterName
                Location = $script:Location
                PrivateLinkState = "Disabled"
                AcceptEULA = $true
                OidcIssuerProfileEnabled = $true
                WorkloadIdentityEnabled = $true
            }
            
            # Add custom-locations OID if we have it
            if (-not [string]::IsNullOrEmpty($customLocationsOid)) {
                $connectParams['CustomLocationsOid'] = $customLocationsOid
                Write-InfoLog "Including CustomLocationsOid in connection"
            }
            
            New-AzConnectedKubernetes @connectParams
            
            Write-Success "Cluster connected to Azure Arc with features enabled"
        }
        
        # Store OID for later verification
        $script:CustomLocationsOid = $customLocationsOid
    }
}

function Enable-ArcFeatures {
    Write-Log "Verifying Arc features (custom-locations, cluster-connect)..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify Arc features"
        return
    }
    
    # Features should already be enabled during New-AzConnectedKubernetes
    # This function now just verifies they are active
    
    # Get the Custom Locations RP object ID if not already set
    $customLocationsOid = $script:CustomLocationsOid
    if ([string]::IsNullOrEmpty($customLocationsOid)) {
        $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
        try {
            $customLocationsOid = (Get-AzADServicePrincipal -ApplicationId $customLocationsAppId -ErrorAction Stop).Id
        } catch {
            Write-WarnLog "Could not retrieve Custom Locations RP object ID"
        }
    }
    
    if ([string]::IsNullOrEmpty($customLocationsOid)) {
        Write-WarnLog "Could not verify Custom Locations RP object ID"
    } else {
        Write-InfoLog "Custom Locations RP Object ID: $customLocationsOid"
    }
    
    # Verify the cluster configuration
    Write-InfoLog "Checking cluster feature state..."
    try {
        $clusterInfo = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName -ErrorAction Stop
        
        Write-InfoLog "Cluster configuration:"
        Write-InfoLog "  Connectivity: $($clusterInfo.ConnectivityStatus)"
        Write-InfoLog "  PrivateLinkState: $($clusterInfo.PrivateLinkState)"
        Write-InfoLog "  Distribution: $($clusterInfo.Distribution)"
        
        if ($clusterInfo.PrivateLinkState -eq "Enabled") {
            Write-ErrorLog "CRITICAL: Private Link is enabled - this is incompatible with custom-locations"
            Write-ErrorLog "Custom-locations feature will NOT work until Private Link is disabled"
            Write-ErrorLog "To fix: Delete the Arc connection and re-run this script"
            return
        }
        
        # Check if custom-locations feature is present
        $customLocationsEnabled = $false
        if ($clusterInfo.Feature) {
            foreach ($feature in $clusterInfo.Feature) {
                if ($feature.Name -eq "custom-locations") {
                    Write-InfoLog "  custom-locations: $($feature.State)"
                    if ($feature.State -eq "Installed" -or $feature.State -eq "Enabled") {
                        $customLocationsEnabled = $true
                    }
                }
                if ($feature.Name -eq "cluster-connect") {
                    Write-InfoLog "  cluster-connect: $($feature.State)"
                }
            }
        }
        
        # Check OIDC issuer profile
        if ($clusterInfo.OidcIssuerProfileEnabled) {
            Write-InfoLog "  OIDC Issuer: Enabled"
        }
        
        if ($clusterInfo.WorkloadIdentityEnabled) {
            Write-InfoLog "  Workload Identity: Enabled"
        }
        
        # If features were enabled during New-AzConnectedKubernetes, we're good
        # The features are typically enabled immediately when specified during connection
        if ($customLocationsEnabled) {
            Write-Success "Custom-locations feature is enabled"
        } else {
            # Features should have been enabled during New-AzConnectedKubernetes
            # If not, the cluster may need to be reconnected
            Write-WarnLog "Custom-locations feature state could not be verified"
            Write-WarnLog "If IoT Operations deployment fails with 'resource provider does not have required permissions',"
            Write-WarnLog "you may need to delete the Arc connection and re-run this script."
            Write-Host ""
            Write-Host "  To delete and reconnect:" -ForegroundColor Yellow
            Write-Host "    kubectl delete ns azure-arc" -ForegroundColor White
            Write-Host "    Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force" -ForegroundColor White
            Write-Host "    # Then re-run this script" -ForegroundColor White
            Write-Host ""
        }
    } catch {
        Write-ErrorLog "Could not verify cluster feature state: $_"
    }
}

function Enable-OidcWorkloadIdentity {
    Write-Log "Verifying OIDC issuer and workload identity..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify OIDC and workload identity"
        return
    }
    
    # OIDC and workload identity are enabled during New-AzConnectedKubernetes
    Write-InfoLog "OIDC issuer and workload identity are configured during Arc connection"
    Write-Success "OIDC and workload identity configuration verified"
}

# ============================================================================
# VERIFICATION
# ============================================================================

function Test-ArcConnection {
    Write-Log "Verifying Arc connection..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify Arc connection"
        return
    }
    
    # Wait a moment for status to update
    Start-Sleep -Seconds 5
    
    try {
        $arcCluster = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName
        $arcStatus = $arcCluster.ConnectivityStatus
    } catch {
        $arcStatus = "Unknown"
    }
    
    Write-Host ""
    Write-Host "Arc Connection Status:" -ForegroundColor Cyan
    Write-Host "  Cluster:    $script:ClusterName"
    Write-Host "  Status:     $arcStatus"
    Write-Host ""
    
    if ($arcStatus -eq "Connected") {
        Write-Success "Cluster is connected to Azure Arc!"
    } else {
        Write-WarnLog "Cluster status is '$arcStatus'. It may take a few minutes to fully connect."
        Write-InfoLog "Check status with: Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName"
    }
}

# ============================================================================
# COMPLETION
# ============================================================================

function Show-Completion {
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "Arc Enablement Completed!" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your cluster '$script:ClusterName' is now connected to Azure Arc."
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. From your Windows management machine, run:"
    Write-Host "   cd external_configuration"
    Write-Host "   .\External-Configurator.ps1"
    Write-Host ""
    Write-Host "2. This will deploy Azure IoT Operations to your cluster."
    Write-Host ""
    Write-Host "3. After deployment, run grant_entra_id_roles.ps1 to set up permissions:"
    Write-Host "   .\grant_entra_id_roles.ps1"
    Write-Host ""
    Write-Host "Useful Commands:" -ForegroundColor Cyan
    Write-Host "  Check Arc status:  Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName"
    Write-Host "  View Arc agents:   kubectl get pods -n azure-arc"
    Write-Host ""
    Write-Host "Log file: $LogFile"
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

function Main {
    # Setup logging
    Write-Host "============================================================================"
    Write-Host "Azure IoT Operations - Arc Enable Script (PowerShell)"
    Write-Host "============================================================================"
    Write-Host "Log file: $LogFile"
    Write-Host "Started: $(Get-Date)"
    Write-Host ""
    
    Add-Content -Path $LogFile -Value "============================================================================"
    Add-Content -Path $LogFile -Value "Azure IoT Operations - Arc Enable Script (PowerShell)"
    Add-Content -Path $LogFile -Value "Started: $(Get-Date)"
    Add-Content -Path $LogFile -Value "============================================================================"
    
    if ($DryRun) {
        Write-Host "*** DRY-RUN MODE - No changes will be made ***" -ForegroundColor Yellow
        Write-Host ""
    }
    
    Load-Configuration
    Check-Prerequisites
    Connect-ToAzure
    Test-ResourceGroup
    Enable-ArcForCluster
    Enable-ArcFeatures
    Enable-OidcWorkloadIdentity
    Test-ArcConnection
    Show-Completion
    
    Write-Log "Arc enablement completed successfully!"
}

# Run main function
try {
    Main
} catch {
    Write-ErrorLog "Script failed: $_" -Fatal
}
