<#
.SYNOPSIS
    Deploy MQTT assets to Azure IoT Operations using ARM templates
.DESCRIPTION
    This script deploys MQTT asset endpoint profiles and assets to Azure using ARM templates.
    It can be run remotely from Windows using Azure Arc proxy connectivity.
.PARAMETER ConfigPath
    Path to linux_aio_config.json. If not specified, searches in edge_configs/ or current directory.
.PARAMETER ResourceGroup
    Override resource group from config file
.PARAMETER ClusterName
    Override cluster name from config file
.EXAMPLE
    .\Deploy-Assets.ps1
.EXAMPLE
    .\Deploy-Assets.ps1 -ResourceGroup "IoT-Operations" -ClusterName "iot-ops-cluster"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$ClusterName
)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script variables
$script:ScriptDir = $PSScriptRoot
$script:LogFile = Join-Path $script:ScriptDir "deploy_assets_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:StartTime = Get-Date

#region Logging Functions

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Level: $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "INFO"    { Write-Host $logMessage -ForegroundColor Cyan }
        default   { Write-Host $logMessage }
    }
    
    Add-Content -Path $script:LogFile -Value $logMessage
}

function Write-ErrorLog {
    param([string]$Message)
    Write-Log -Message $Message -Level "ERROR"
}

function Write-WarnLog {
    param([string]$Message)
    Write-Log -Message $Message -Level "WARNING"
}

function Write-Success {
    param([string]$Message)
    Write-Log -Message $Message -Level "SUCCESS"
}

function Write-InfoLog {
    param([string]$Message)
    Write-Log -Message $Message -Level "INFO"
}

#endregion

#region Configuration Functions

function Find-ConfigFile {
    Write-InfoLog "Searching for linux_aio_config.json..."
    
    $searchPaths = @(
        $ConfigPath,
        (Join-Path $script:ScriptDir "edge_configs\linux_aio_config.json"),
        (Join-Path $script:ScriptDir "linux_aio_config.json")
    )
    
    foreach ($path in $searchPaths) {
        if ($path -and (Test-Path $path)) {
            Write-InfoLog "Checking: $path"
            Write-Success "Found configuration at: $path"
            return $path
        }
    }
    
    throw "Configuration file linux_aio_config.json not found in any search location"
}

function Load-Configuration {
    param([string]$ConfigFilePath)
    
    Write-InfoLog "Loading configuration from: $ConfigFilePath"
    
    $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
    
    # Override with parameters if provided
    if ($ResourceGroup) {
        $config.azure.resource_group = $ResourceGroup
    }
    if ($ClusterName) {
        $config.azure.cluster_name = $ClusterName
    }
    
    Write-Host "`nConfiguration:"
    Write-Host "  Resource Group: $($config.azure.resource_group)"
    Write-Host "  Location: $($config.azure.location)"
    Write-Host "  Cluster: $($config.azure.cluster_name)"
    Write-Host ""
    
    return $config
}

#endregion

#region Deployment Functions

function Get-CustomLocation {
    param(
        [string]$ClusterName,
        [string]$ResourceGroup
    )
    
    Write-InfoLog "Getting custom location from Arc cluster: $ClusterName"
    
    try {
        $customLocation = az connectedk8s show `
            --name $ClusterName `
            --resource-group $ResourceGroup `
            --query "id" -o tsv 2>$null
        
        if ($customLocation) {
            Write-Success "Custom location found: $customLocation"
            return $customLocation
        } else {
            Write-WarnLog "Could not auto-detect custom location"
            Write-WarnLog "You may need to manually specify the custom location in ARM templates"
            return $null
        }
    }
    catch {
        Write-WarnLog "Error getting custom location: $_"
        return $null
    }
}

function Deploy-AssetEndpoint {
    param(
        [string]$ResourceGroup,
        [string]$Location
    )
    
    Write-InfoLog "Deploying MQTT Asset Endpoint Profile via ARM template..."
    
    $templatePath = Join-Path $script:ScriptDir "arm_templates\mqtt-asset-endpoint.json"
    
    if (-not (Test-Path $templatePath)) {
        throw "ARM template not found: $templatePath"
    }
    
    $deploymentName = "mqtt-endpoint-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
    
    $result = az deployment group create `
        --resource-group $ResourceGroup `
        --template-file $templatePath `
        --parameters location=$Location `
        --name $deploymentName `
        2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Asset endpoint profile deployed successfully"
    } else {
        Write-ErrorLog "Failed to deploy asset endpoint profile"
        Write-ErrorLog $result
        throw "Deployment failed"
    }
}

function Deploy-Asset {
    param(
        [string]$ResourceGroup,
        [string]$Location
    )
    
    Write-InfoLog "Deploying MQTT Asset via ARM template..."
    
    $templatePath = Join-Path $script:ScriptDir "arm_templates\mqtt-asset.json"
    
    if (-not (Test-Path $templatePath)) {
        throw "ARM template not found: $templatePath"
    }
    
    $deploymentName = "mqtt-asset-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
    
    $result = az deployment group create `
        --resource-group $ResourceGroup `
        --template-file $templatePath `
        --parameters location=$Location `
        --name $deploymentName `
        2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Asset deployed successfully"
    } else {
        Write-ErrorLog "Failed to deploy asset"
        Write-ErrorLog $result
        throw "Deployment failed"
    }
}

function Verify-Deployment {
    param(
        [string]$ResourceGroup
    )
    
    Write-InfoLog "Verifying deployment..."
    
    Write-Host "`n=== Asset Endpoint Profiles ===" -ForegroundColor Cyan
    az resource list `
        --resource-group $ResourceGroup `
        --resource-type "Microsoft.DeviceRegistry/assetEndpointProfiles" `
        --query "[].{Name:name, Location:location}" `
        -o table
    
    Write-Host "`n=== Assets ===" -ForegroundColor Cyan
    az resource list `
        --resource-group $ResourceGroup `
        --resource-type "Microsoft.DeviceRegistry/assets" `
        --query "[].{Name:name, Location:location}" `
        -o table
    
    Write-Success "Deployment verification completed"
}

function Show-DeploymentSummary {
    param(
        [string]$ResourceGroup
    )
    
    $subscriptionId = az account show --query id -o tsv
    
    Write-Host "`n============================================================================" -ForegroundColor Green
    Write-Host "Asset Deployment Completed!" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    
    Write-Host "`nView resources in Azure Portal:"
    Write-Host "  Resource Group: https://portal.azure.com/#@/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/overview"
    Write-Host "  Assets: https://portal.azure.com/#@/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DeviceRegistry/assets"
    
    $duration = (Get-Date) - $script:StartTime
    Write-Host "`nDeployment completed in $([math]::Round($duration.TotalMinutes, 2)) minutes"
    Write-Host "Log file: $script:LogFile"
    Write-Host ""
}

#endregion

#region Main Execution

function Main {
    try {
        # Start transcript
        Start-Transcript -Path $script:LogFile -Append
        
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Azure IoT Operations - Asset Deployment" -ForegroundColor Cyan
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Log file: $script:LogFile"
        Write-Host "Started: $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')"
        Write-Host "Script directory: $script:ScriptDir"
        Write-Host ""
        
        # Check Azure CLI
        Write-InfoLog "Checking Azure CLI..."
        $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
        if (-not $azVersion) {
            throw "Azure CLI is not installed or not in PATH"
        }
        Write-Success "Azure CLI version: $azVersion"
        
        # Find and load configuration
        $configPath = Find-ConfigFile
        $config = Load-Configuration -ConfigFilePath $configPath
        
        # Check Azure authentication
        Write-InfoLog "Checking Azure authentication..."
        $account = az account show 2>$null | ConvertFrom-Json
        if (-not $account) {
            throw "Not logged into Azure. Run 'az login' first."
        }
        Write-Success "Logged into Azure as: $($account.user.name)"
        Write-InfoLog "Subscription: $($account.name)"
        
        # Get custom location (optional)
        $customLocation = Get-CustomLocation -ClusterName $config.azure.cluster_name -ResourceGroup $config.azure.resource_group
        
        # Deploy assets
        Write-Host "`n=== Deploying MQTT Assets ===" -ForegroundColor Cyan
        Deploy-AssetEndpoint -ResourceGroup $config.azure.resource_group -Location $config.azure.location
        Write-Host ""
        Deploy-Asset -ResourceGroup $config.azure.resource_group -Location $config.azure.location
        
        # Verify deployment
        Write-Host ""
        Verify-Deployment -ResourceGroup $config.azure.resource_group
        
        # Show summary
        Show-DeploymentSummary -ResourceGroup $config.azure.resource_group
        
        Write-Success "Asset deployment completed successfully!"
        
    }
    catch {
        Write-ErrorLog "Deployment failed: $_"
        Write-ErrorLog $_.Exception.Message
        Write-ErrorLog "Stack Trace: $($_.ScriptStackTrace)"
        
        Write-Host "`n============================================================================" -ForegroundColor Red
        Write-Host "Asset Deployment Failed!" -ForegroundColor Red
        Write-Host "============================================================================" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host "Check log file for details: $script:LogFile" -ForegroundColor Red
        Write-Host ""
        
        exit 1
    }
    finally {
        Stop-Transcript
    }
}

# Execute main function
Main

#endregion
