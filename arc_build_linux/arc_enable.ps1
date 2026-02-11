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
$script:KeyVaultName = ""

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
    $script:KeyVaultName = $config.azure.key_vault_name
    
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
    Write-Host "  Key Vault:      $script:KeyVaultName"
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
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "WARNING: CUSTOM LOCATIONS OID NOT AVAILABLE" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The Custom Locations Resource Provider object ID could not be retrieved."
        Write-Host "This is required for Azure IoT Operations to work properly."
        Write-Host ""
        Write-Host "Possible causes:" -ForegroundColor Cyan
        Write-Host "  - Your account doesn't have permission to read service principals"
        Write-Host "  - The Custom Locations RP is not registered in your tenant"
        Write-Host "  - grant_entra_id_roles.ps1 hasn't been run yet"
        Write-Host ""
        Write-Host "What happens next:" -ForegroundColor Cyan
        Write-Host "  - The cluster will be Arc-connected WITHOUT custom-locations enabled"
        Write-Host "  - IoT Operations deployment will FAIL until this is fixed"
        Write-Host ""
        Write-Host "To fix:" -ForegroundColor Green
        Write-Host "  1. Run grant_entra_id_roles.ps1 from Windows (or get elevated permissions)"
        Write-Host "  2. Delete the Arc connection:"
        Write-Host "       kubectl delete ns azure-arc"
        Write-Host "       (NOTE: 'namespace not found' error is OK - means it's already deleted)" -ForegroundColor DarkGray
        Write-Host "       Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force"
        Write-Host "  3. Re-run this script (it's safe to run multiple times)"
        Write-Host ""
        Write-Host "This script is IDEMPOTENT - you can safely run it again after fixing permissions." -ForegroundColor Green
        Write-Host ""
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
            Write-Host "    (NOTE: 'namespace not found' error is OK - means it's already deleted)" -ForegroundColor DarkGray
            Write-Host "    Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force" -ForegroundColor White
            Write-Host ""
        }
        
        # Check if custom-locations was enabled (idempotency check)
        $hasCustomLocations = $false
        if ($existingArc.Feature) {
            foreach ($feature in $existingArc.Feature) {
                if ($feature.Name -eq "custom-locations" -and ($feature.State -eq "Installed" -or $feature.State -eq "Enabled")) {
                    $hasCustomLocations = $true
                    Write-Success "Custom-locations feature is enabled"
                }
            }
        }
        
        if (-not $hasCustomLocations -and -not [string]::IsNullOrEmpty($customLocationsOid)) {
            # Cluster exists but custom-locations not enabled according to Azure API
            # This is OK - we'll try to enable it later with az connectedk8s enable-features
            Write-InfoLog "Custom-locations not yet enabled - will enable via Azure CLI later in script"
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
            } else {
                Write-WarnLog "Connecting WITHOUT custom-locations (OID not available)"
                Write-WarnLog "IoT Operations will NOT work until you reconnect with custom-locations enabled"
                Write-Host ""
                Write-Host "After fixing permissions, you can re-run this script:" -ForegroundColor Yellow
                Write-Host "  1. Delete the Arc connection:" -ForegroundColor White
                Write-Host "       kubectl delete ns azure-arc" -ForegroundColor White
                Write-Host "       (NOTE: 'namespace not found' error is OK - means it's already deleted)" -ForegroundColor DarkGray
                Write-Host "       Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force" -ForegroundColor White
                Write-Host "  2. Re-run: ./arc_enable.ps1" -ForegroundColor White
                Write-Host ""
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
            Write-Success "Custom-locations feature is registered in Azure"
        } else {
            # Azure API doesn't always show feature state correctly
            # The helm values check in Enable-CustomLocations is the authoritative source
            Write-InfoLog "Custom-locations feature state not reported by Azure API"
            Write-InfoLog "Will enable and verify via Azure CLI next..."
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
    
    # KNOWN ISSUE: Az.ConnectedKubernetes module sets WorkloadIdentityEnabled=true in ARM
    # but does NOT deploy the workload identity webhook pods to the cluster.
    # We need to verify the webhook is running and enable it via CLI if not.
    
    Write-InfoLog "Checking if workload identity webhook is deployed..."
    
    try {
        # Check if workload identity webhook pods are running
        $wiPods = kubectl get pods -n azure-arc 2>$null | Select-String -Pattern "workload-identity"
        
        if ($wiPods) {
            Write-Success "Workload identity webhook is running"
            Write-InfoLog "Pods: $wiPods"
            return
        }
        
        Write-WarnLog "Workload identity webhook NOT found in cluster"
        Write-InfoLog "Azure shows workloadIdentityEnabled=true but webhook pods are not deployed"
        Write-InfoLog "This is a known Az.ConnectedKubernetes module gap - enabling via CLI..."
        
        # Use Azure CLI to properly enable workload identity (deploys the webhook)
        $updateResult = az connectedk8s update `
            --name $script:ClusterName `
            --resource-group $script:ResourceGroup `
            --enable-workload-identity 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-WarnLog "az connectedk8s update failed: $updateResult"
            Write-Host ""
            Write-Host "To enable manually, run this command on the edge device:" -ForegroundColor Yellow
            Write-Host "  az connectedk8s update --name $script:ClusterName --resource-group $script:ResourceGroup --enable-workload-identity" -ForegroundColor Cyan
            Write-Host ""
            return
        }
        
        # Verify webhook is now running
        Write-InfoLog "Waiting for workload identity webhook to start..."
        Start-Sleep -Seconds 10
        
        $wiPodsAfter = kubectl get pods -n azure-arc 2>$null | Select-String -Pattern "workload-identity"
        if ($wiPodsAfter) {
            Write-Success "Workload identity webhook is now running!"
            Write-InfoLog "Pods: $wiPodsAfter"
        } else {
            Write-WarnLog "Webhook pods not yet visible. They may take a few minutes to start."
            Write-Host "Verify with: kubectl get pods -n azure-arc | grep workload" -ForegroundColor Cyan
        }
        
    } catch {
        Write-ErrorLog "Failed to verify/enable workload identity: $_"
        Write-Host "To enable manually, run:" -ForegroundColor Yellow
        Write-Host "  az connectedk8s update --name $script:ClusterName --resource-group $script:ResourceGroup --enable-workload-identity" -ForegroundColor Cyan
    }
}

function Test-K3sOidcIssuerConfigured {
    <#
    .SYNOPSIS
        Checks if K3s is configured with the correct Arc OIDC issuer URL.
    
    .DESCRIPTION
        For secret sync to work with workload identity, K3s must issue service 
        account tokens with the Arc OIDC issuer URL (not the default 
        kubernetes.default.svc.cluster.local). This function checks if K3s is
        correctly configured.
        
        Returns a hashtable with:
        - Configured: $true if OIDC issuer matches Arc issuer
        - CurrentIssuer: Current K3s issuer URL (or $null if default)
        - ExpectedIssuer: Arc OIDC issuer URL
    #>
    
    Write-InfoLog "Checking K3s OIDC issuer configuration..."
    
    $result = @{
        Configured = $false
        CurrentIssuer = $null
        ExpectedIssuer = $null
        K3sReady = $false
    }
    
    # Check if K3s is running
    $nodesReady = kubectl get nodes --no-headers 2>$null | Select-String -Pattern "Ready"
    if (-not $nodesReady) {
        Write-WarnLog "K3s is not ready (no nodes in Ready state)"
        return $result
    }
    $result.K3sReady = $true
    
    # Get the expected OIDC issuer URL from Azure
    $expectedIssuer = az connectedk8s show `
        --name $script:ClusterName `
        --resource-group $script:ResourceGroup `
        --query "oidcIssuerProfile.issuerUrl" `
        --output tsv 2>$null
    
    if ([string]::IsNullOrEmpty($expectedIssuer)) {
        Write-WarnLog "OIDC issuer URL not available from Azure yet"
        return $result
    }
    $result.ExpectedIssuer = $expectedIssuer
    
    # Get current K3s issuer
    $clusterDump = kubectl cluster-info dump 2>$null
    $currentIssuer = $clusterDump | Select-String -Pattern "service-account-issuer=([^\s,`"]+)" | 
        ForEach-Object { $_.Matches.Groups[1].Value } | 
        Select-Object -First 1
    
    if ($currentIssuer) {
        $result.CurrentIssuer = $currentIssuer
        
        if ($currentIssuer -eq $expectedIssuer) {
            $result.Configured = $true
            Write-Success "K3s OIDC issuer is correctly configured"
        } else {
            Write-WarnLog "K3s OIDC issuer mismatch"
            Write-InfoLog "  Current:  $currentIssuer"
            Write-InfoLog "  Expected: $expectedIssuer"
        }
    } else {
        Write-InfoLog "K3s using default issuer (kubernetes.default.svc.cluster.local)"
    }
    
    return $result
}

function Configure-K3sOidcIssuer {
    <#
    .SYNOPSIS
        Configures K3s to use the Arc OIDC issuer URL for service account tokens.
    
    .DESCRIPTION
        After Arc connection, retrieves the OIDC issuer URL from Azure and configures
        K3s to issue service account tokens with that issuer. This is REQUIRED for
        workload identity and secret sync to work properly.
        
        Without this configuration, K3s issues tokens with the default issuer
        'https://kubernetes.default.svc.cluster.local' which doesn't match the
        federated identity credentials created by Azure, causing secret sync to fail.
        
        Safe to run multiple times - checks current state before making changes.
    #>
    
    Write-Log "Configuring K3s OIDC issuer for secret sync..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would configure K3s OIDC issuer"
        return $true
    }
    
    # Check current configuration
    $oidcStatus = Test-K3sOidcIssuerConfigured
    
    if ($oidcStatus.Configured) {
        Write-Success "K3s already configured with correct OIDC issuer"
        return $true
    }
    
    if (-not $oidcStatus.K3sReady) {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "K3S NOT READY" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "K3s is not running or restarting." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Check K3s status and run this script again:" -ForegroundColor Gray
        Write-Host "  kubectl get nodes"
        Write-Host "  sudo systemctl status k3s"
        Write-Host ""
        return $false
    }
    
    if (-not $oidcStatus.ExpectedIssuer) {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "ARC OIDC ISSUER NOT AVAILABLE" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The Arc OIDC issuer URL is not yet available from Azure." -ForegroundColor Cyan
        Write-Host "Arc may still be initializing. This typically takes 2-5 minutes."
        Write-Host ""
        Write-Host "Run this script again in a few minutes." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To check Arc status manually:" -ForegroundColor Gray
        Write-Host "  kubectl get pods -n azure-arc"
        Write-Host "  az connectedk8s show --name $script:ClusterName --resource-group $script:ResourceGroup --query '{status:connectivityStatus, oidc:oidcIssuerProfile.issuerUrl}'"
        Write-Host ""
        return $false
    }
    
    $oidcIssuerUrl = $oidcStatus.ExpectedIssuer
    Write-InfoLog "OIDC Issuer URL: $oidcIssuerUrl"
    Write-InfoLog "Updating K3s configuration..."
    
    # Create the K3s config file content
    $k3sConfig = @"
kube-apiserver-arg:
  - 'service-account-issuer=$oidcIssuerUrl'
  - 'service-account-max-token-expiration=24h'
"@
    
    $configPath = "/etc/rancher/k3s/config.yaml"
    
    # Check if config file exists and has other settings we should preserve
    $existingConfig = $null
    try {
        $existingConfig = (sudo cat $configPath 2>$null) -join "`n"
    } catch {}
    
    if ($existingConfig -and $existingConfig -notmatch "service-account-issuer") {
        # Append to existing config (preserving other settings)
        Write-InfoLog "Appending OIDC issuer to existing K3s config..."
        $k3sConfig = $existingConfig.TrimEnd() + "`n" + $k3sConfig
    } elseif ($existingConfig -and $existingConfig -match "service-account-issuer") {
        # Config already has an issuer setting - replace the whole file
        Write-InfoLog "Replacing existing OIDC issuer in K3s config..."
    }
    
    # Write the config file
    $k3sConfig | sudo tee $configPath > $null
    
    Write-InfoLog "Restarting K3s to apply OIDC issuer configuration..."
    sudo systemctl restart k3s
    
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "K3S OIDC ISSUER CONFIGURED" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "K3s is restarting with the Arc OIDC issuer. This takes 60-90 seconds." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Run this script again to verify the configuration is complete." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To check K3s status manually:" -ForegroundColor Gray
    Write-Host "  kubectl get nodes"
    Write-Host "  kubectl cluster-info dump | grep service-account-issuer"
    Write-Host ""
    Write-Host "Once K3s is ready, secret sync will work correctly for:" -ForegroundColor Gray
    Write-Host "  - Azure Key Vault secrets to Kubernetes"
    Write-Host "  - Dataflow endpoints with SASL authentication"
    Write-Host ""
    
    # Exit script - user should re-run after K3s restarts
    return $false
}

function Create-FabricSecretPlaceholders {
    <#
    .SYNOPSIS
        Creates placeholder secrets in Key Vault for Microsoft Fabric Event Streams.
    
    .DESCRIPTION
        Creates two secrets in Azure Key Vault for Fabric Kafka/SASL authentication:
        - fabric-sasl-username: Set to '$ConnectionString' (required by Fabric)
        - fabric-sasl-password: Set to a placeholder prompting user to add their connection string
        
        These secrets can then be synced to Kubernetes via AIO's secret sync feature.
        After running this, update fabric-sasl-password with your actual Fabric connection string.
        
        Safe to run multiple times - will not overwrite existing password if it's been set.
    #>
    
    Write-Log "Creating Fabric Event Streams secret placeholders..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would create Fabric secret placeholders in Key Vault"
        return $true
    }
    
    if ([string]::IsNullOrEmpty($script:KeyVaultName)) {
        Write-WarnLog "Key Vault name not configured in aio_config.json"
        Write-InfoLog "Skipping Fabric secret creation. You can create them manually later."
        return $true
    }
    
    $usernameSecretName = "fabric-sasl-username"
    $passwordSecretName = "fabric-sasl-password"
    $usernameValue = '$ConnectionString'
    $passwordPlaceholder = "PUT_YOUR_FABRIC_KAFKA_CONNECTION_STRING_HERE"
    
    try {
        # Check if username secret exists
        $existingUsername = az keyvault secret show `
            --vault-name $script:KeyVaultName `
            --name $usernameSecretName `
            --query "value" -o tsv 2>$null
        
        if ($existingUsername -eq $usernameValue) {
            Write-InfoLog "Secret '$usernameSecretName' already exists with correct value"
        } else {
            Write-InfoLog "Creating secret '$usernameSecretName'..."
            az keyvault secret set `
                --vault-name $script:KeyVaultName `
                --name $usernameSecretName `
                --value $usernameValue > $null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Created secret '$usernameSecretName'"
            } else {
                Write-WarnLog "Failed to create secret '$usernameSecretName'"
            }
        }
        
        # Check if password secret exists and has been customized
        $existingPassword = az keyvault secret show `
            --vault-name $script:KeyVaultName `
            --name $passwordSecretName `
            --query "value" -o tsv 2>$null
        
        if ($existingPassword -and $existingPassword -ne $passwordPlaceholder) {
            Write-InfoLog "Secret '$passwordSecretName' already exists with custom value (not overwriting)"
        } elseif ($existingPassword -eq $passwordPlaceholder) {
            Write-InfoLog "Secret '$passwordSecretName' already exists with placeholder value"
        } else {
            Write-InfoLog "Creating placeholder secret '$passwordSecretName'..."
            az keyvault secret set `
                --vault-name $script:KeyVaultName `
                --name $passwordSecretName `
                --value $passwordPlaceholder > $null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Created placeholder secret '$passwordSecretName'"
            } else {
                Write-WarnLog "Failed to create secret '$passwordSecretName'"
            }
        }
        
        Write-Host ""
        Write-Host "Fabric Secret Setup:" -ForegroundColor Cyan
        Write-Host "  Key Vault:       $script:KeyVaultName"
        Write-Host "  Username Secret: $usernameSecretName = '$usernameValue'"
        Write-Host "  Password Secret: $passwordSecretName"
        Write-Host ""
        Write-Host "To set your Fabric connection string:" -ForegroundColor Yellow
        Write-Host "  1. Go to Microsoft Fabric > Event Stream > ... > Connection Settings"
        Write-Host "  2. Copy the Kafka connection string"
        Write-Host "  3. Update the secret:"
        Write-Host ""
        Write-Host "  az keyvault secret set --vault-name $script:KeyVaultName --name $passwordSecretName --value 'YOUR_CONNECTION_STRING'" -ForegroundColor Cyan
        Write-Host ""
        
        return $true
        
    } catch {
        Write-WarnLog "Failed to create Fabric secrets: $_"
        Write-InfoLog "You can create them manually with:"
        Write-Host "  az keyvault secret set --vault-name $script:KeyVaultName --name $usernameSecretName --value '`$ConnectionString'"
        Write-Host "  az keyvault secret set --vault-name $script:KeyVaultName --name $passwordSecretName --value 'YOUR_CONNECTION_STRING'"
        return $true  # Don't fail the whole script
    }
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

# Track whether custom-locations was successfully enabled
$script:CustomLocationsEnabled = $false

function Enable-CustomLocations {
    <#
    .SYNOPSIS
        Enables custom-locations feature using Azure CLI.
    
    .DESCRIPTION
        IMPORTANT: The Az.ConnectedKubernetes PowerShell module has a bug/gap.
        When you use New-AzConnectedKubernetes with -CustomLocationsOid, it:
          1. Registers the OID with Azure ARM (done)
          2. Does NOT run 'helm upgrade' to actually enable the feature in the cluster (MISSING)
        
        The Azure CLI 'az connectedk8s enable-features' does BOTH steps.
        This function uses the Azure CLI to properly enable custom-locations.
    #>
    
    Write-Log "Enabling custom-locations feature..."
    
    $customLocationsOid = $script:CustomLocationsOid
    if ([string]::IsNullOrEmpty($customLocationsOid)) {
        $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
        try {
            $customLocationsOid = (Get-AzADServicePrincipal -ApplicationId $customLocationsAppId -ErrorAction Stop).Id
        } catch {
            Write-WarnLog "Could not retrieve Custom Locations RP object ID"
            return
        }
    }
    
    Write-InfoLog "Custom Locations OID: $customLocationsOid"
    
    # Check current status
    Write-InfoLog "Checking current custom-locations status..."
    try {
        $currentValues = helm get values azure-arc --namespace azure-arc-release -o json 2>$null | ConvertFrom-Json
        $currentEnabled = $currentValues.systemDefaultValues.customLocations.enabled
        
        if ($currentEnabled -eq $true) {
            Write-Success "Custom-locations is already enabled!"
            Write-InfoLog "Current configuration:"
            helm get values azure-arc --namespace azure-arc-release -o json | jq '.systemDefaultValues.customLocations'
            $script:CustomLocationsEnabled = $true
            return
        }
    } catch {
        Write-InfoLog "Could not check current status, proceeding with enablement..."
    }
    
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would run: az connectedk8s enable-features --name $script:ClusterName --resource-group $script:ResourceGroup --features cluster-connect custom-locations --custom-locations-oid $customLocationsOid" -ForegroundColor Yellow
        $script:CustomLocationsEnabled = $true
        return
    }
    
    # Use Azure CLI - it's the most reliable method
    # The CLI handles both ARM registration AND helm upgrade internally
    Write-InfoLog "Using Azure CLI to enable custom-locations feature..."
    
    try {
        $enableResult = az connectedk8s enable-features `
            --name $script:ClusterName `
            --resource-group $script:ResourceGroup `
            --features cluster-connect custom-locations `
            --custom-locations-oid $customLocationsOid 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # Check if it failed because features are already enabled
            if ($enableResult -match "already enabled" -or $enableResult -match "already registered") {
                Write-InfoLog "Features may already be enabled, verifying..."
            } else {
                Write-ErrorLog "az connectedk8s enable-features failed: $enableResult"
                Write-WarnLog "Custom-locations could not be enabled automatically."
                Write-Host ""
                Write-Host "To enable manually, run this command on the edge device:" -ForegroundColor Yellow
                Write-Host "  az connectedk8s enable-features --name $script:ClusterName --resource-group $script:ResourceGroup --features cluster-connect custom-locations --custom-locations-oid $customLocationsOid" -ForegroundColor Cyan
                Write-Host ""
                return
            }
        }
        
        # Verify it worked
        Write-InfoLog "Verifying custom-locations is enabled..."
        Start-Sleep -Seconds 3
        
        $verifyResult = helm get values azure-arc --namespace azure-arc-release -o json 2>$null | ConvertFrom-Json
        if ($verifyResult.systemDefaultValues.customLocations.enabled -eq $true) {
            Write-Success "Custom-locations feature is now enabled!"
            Write-InfoLog "Configuration:"
            helm get values azure-arc --namespace azure-arc-release -o json | jq '.systemDefaultValues.customLocations'
            $script:CustomLocationsEnabled = $true
        } else {
            Write-WarnLog "Helm values don't show custom-locations as enabled."
            Write-WarnLog "The Azure API may show it as enabled, but cluster configuration may need time to sync."
            Write-Host ""
            Write-Host "Verify manually with:" -ForegroundColor Yellow
            Write-Host "  helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'" -ForegroundColor Cyan
            Write-Host ""
        }
        
    } catch {
        Write-ErrorLog "Failed to enable custom-locations: $_"
        Write-WarnLog "Manual step required. Run:"
        Write-Host "  az connectedk8s enable-features --name $script:ClusterName --resource-group $script:ResourceGroup --features cluster-connect custom-locations --custom-locations-oid $customLocationsOid" -ForegroundColor Cyan
    }
}

function Show-Completion {
    Write-Host ""
    
    if ($script:CustomLocationsEnabled) {
        Write-Host "============================================================================" -ForegroundColor Green
        Write-Host "Arc Enablement Completed Successfully!" -ForegroundColor Green
        Write-Host "============================================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Your cluster '$script:ClusterName' is now connected to Azure Arc."
        Write-Host "  - Custom-locations feature is enabled" -ForegroundColor Green
        Write-Host "  - K3s OIDC issuer configured for secret sync" -ForegroundColor Green
    } else {
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "Arc Enablement Completed (with warnings)" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Your cluster '$script:ClusterName' is connected to Azure Arc."
        Write-Host "  - K3s OIDC issuer configured for secret sync" -ForegroundColor Green
        Write-Host "  - Custom-locations could NOT be verified" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Before proceeding, verify custom-locations manually:" -ForegroundColor Cyan
        Write-Host "  helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'"
        Write-Host ""
        Write-Host "If 'enabled' is not true, run:" -ForegroundColor Cyan
        Write-Host "  az connectedk8s enable-features --name $script:ClusterName --resource-group $script:ResourceGroup --features cluster-connect custom-locations"
    }
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
    Write-Host "  Verify OIDC issuer: kubectl cluster-info dump | grep service-account-issuer"
    Write-Host "  Verify custom-locations: helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'"
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
    
    # Configure K3s OIDC issuer for secret sync
    # This may exit early if K3s needs to restart - user should re-run
    $oidcConfigured = Configure-K3sOidcIssuer
    if (-not $oidcConfigured) {
        Write-Log "Script exiting - re-run after K3s restarts to complete configuration"
        exit 0
    }
    
    # Create placeholder secrets for Fabric Event Streams
    Create-FabricSecretPlaceholders
    
    Enable-CustomLocations  # Enable custom-locations via Azure CLI
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
