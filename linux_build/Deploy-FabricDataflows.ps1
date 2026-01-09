<#
.SYNOPSIS
    Deploy Microsoft Fabric dataflows for Azure IoT Operations
.DESCRIPTION
    This script deploys dataflow configurations to route MQTT messages from edge devices
    to Microsoft Fabric Real-Time Intelligence. Can be run remotely from Windows using
    Azure Arc proxy connectivity.
.PARAMETER ConfigPath
    Path to linux_aio_config.json. If not specified, searches in edge_configs/ or current directory.
.PARAMETER Strategy
    Deployment strategy: 'Aggregated' (default, all data in one stream) or 'PerMachine' (separate streams per machine type)
.PARAMETER ResourceGroup
    Override resource group from config file
.PARAMETER SubscriptionId
    Override subscription ID from config file
.EXAMPLE
    .\Deploy-FabricDataflows.ps1
.EXAMPLE
    .\Deploy-FabricDataflows.ps1 -Strategy Aggregated
.EXAMPLE
    .\Deploy-FabricDataflows.ps1 -Strategy PerMachine -ResourceGroup "IoT-Operations"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Aggregated", "PerMachine")]
    [string]$Strategy,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script variables
$script:ScriptDir = $PSScriptRoot
$script:LogFile = Join-Path $script:ScriptDir "deploy_fabric_dataflows_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
    if ($SubscriptionId) {
        $config.azure.subscription_id = $SubscriptionId
    }
    
    Write-Host "`nAzure Configuration:"
    Write-Host "  Subscription: $($config.azure.subscription_id)"
    Write-Host "  Resource Group: $($config.azure.resource_group)"
    Write-Host "  Cluster: $($config.azure.cluster_name)"
    Write-Host "  AIO Instance: $($config.azure.aio_instance_name)"
    Write-Host ""
    
    return $config
}

#endregion

#region Validation Functions

function Test-Prerequisites {
    Write-InfoLog "Checking prerequisites..."
    
    # Check kubectl
    try {
        $kubectlVersion = kubectl version --client --short 2>$null
        if ($kubectlVersion) {
            Write-Success "kubectl found: $kubectlVersion"
        } else {
            throw "kubectl not found or not responding"
        }
    }
    catch {
        throw "kubectl is not installed or not in PATH. Install from: https://kubernetes.io/docs/tasks/tools/"
    }
    
    # Check Azure CLI
    try {
        $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
        if ($azVersion) {
            Write-Success "Azure CLI version: $azVersion"
        } else {
            throw "Azure CLI not found"
        }
    }
    catch {
        throw "Azure CLI is not installed or not in PATH"
    }
    
    # Check cluster connection
    Write-InfoLog "Checking cluster connection..."
    try {
        $clusterInfo = kubectl cluster-info 2>&1
        if ($LASTEXITCODE -eq 0) {
            $currentContext = kubectl config current-context 2>$null
            Write-Success "Connected to cluster: $currentContext"
        } else {
            throw "Not connected to Kubernetes cluster"
        }
    }
    catch {
        throw "Cannot connect to Kubernetes cluster. Ensure kubectl is configured with Arc proxy context."
    }
    
    # Check azure-iot-operations namespace
    Write-InfoLog "Checking azure-iot-operations namespace..."
    $namespace = kubectl get namespace azure-iot-operations 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Namespace azure-iot-operations exists"
    } else {
        throw "Namespace azure-iot-operations not found. Ensure Azure IoT Operations is installed."
    }
}

function Get-CustomLocation {
    param([object]$Config)
    
    $customLocation = $Config.azure.custom_location_name
    
    if (-not $customLocation) {
        Write-ErrorLog "custom_location_name not found in config file"
        Write-Host "`nAvailable custom locations:" -ForegroundColor Yellow
        az customlocation list -g $Config.azure.resource_group -o table
        
        throw "Please add custom_location_name to linux_aio_config.json in the azure section"
    }
    
    Write-Success "Custom Location: $customLocation"
    return $customLocation
}

function Get-FabricConfiguration {
    param([object]$Config)
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Fabric Eventstream Configuration" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    $fabricTopicId = if ($Config.fabric.eventstream_topic_id) { 
        $Config.fabric.eventstream_topic_id 
    } else { 
        "es_YOUR_FABRIC_TOPIC_ID" 
    }
    
    $alertsTopicId = if ($Config.fabric.eventstream_alerts_topic_id) { 
        $Config.fabric.eventstream_alerts_topic_id 
    } else { 
        "es_YOUR_FABRIC_ALERTS_TOPIC" 
    }
    
    Write-Host "Eventstream Topic ID: $fabricTopicId"
    Write-Host "Alerts Topic ID: $alertsTopicId"
    Write-Host ""
    
    # Validate topic IDs
    if ($fabricTopicId -eq "es_YOUR_FABRIC_TOPIC_ID") {
        Write-WarnLog "Using placeholder topic ID from config file."
        Write-Host "`nTo configure Fabric Eventstream:" -ForegroundColor Yellow
        Write-Host "  1. Go to https://app.fabric.microsoft.com"
        Write-Host "  2. Create or open your Eventstream"
        Write-Host "  3. Copy the topic ID (format: es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb)"
        Write-Host "  4. Update linux_build/linux_aio_config.json:"
        Write-Host '     "eventstream_topic_id": "es_YOUR_ACTUAL_TOPIC_ID"'
        Write-Host ""
        
        $continue = Read-Host "Continue with placeholder? (y/N)"
        if ($continue -notmatch "^[Yy]$") {
            throw "Deployment cancelled. Please update config file first."
        }
    } else {
        Write-Success "Topic IDs loaded from config"
    }
    
    return @{
        TopicId = $fabricTopicId
        AlertsTopicId = $alertsTopicId
    }
}

#endregion

#region Deployment Functions

function Deploy-FabricEndpoint {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Deploying Fabric Endpoint" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Check if endpoint already exists
    $endpoint = kubectl get dataflowendpoint fabric-realtime -n azure-iot-operations 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Fabric endpoint already exists"
        return
    }
    
    # Look for endpoint YAML file
    $endpointPath = Join-Path (Split-Path $script:ScriptDir) "operations\fabric-realtime-endpoint.yaml"
    
    if (Test-Path $endpointPath) {
        Write-InfoLog "Applying fabric-realtime-endpoint.yaml..."
        kubectl apply -f $endpointPath
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Fabric endpoint deployed"
        } else {
            Write-WarnLog "Failed to deploy fabric endpoint"
        }
    } else {
        Write-WarnLog "fabric-realtime-endpoint.yaml not found. Skipping..."
    }
}

function Select-DeploymentStrategy {
    if ($Strategy) {
        Write-InfoLog "Using specified strategy: $Strategy"
        return $Strategy
    }
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Select Deployment Strategy" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    Write-Host "1) Aggregated - All factory data in one stream (recommended)"
    Write-Host "2) PerMachine - Separate dataflows for CNC, 3D Printer, Welding"
    Write-Host ""
    
    $choice = Read-Host "Select strategy (1-2)"
    
    switch ($choice) {
        "1" {
            Write-Success "Selected: Aggregated (all data, single stream)"
            return "Aggregated"
        }
        "2" {
            Write-Success "Selected: PerMachine (separate streams)"
            return "PerMachine"
        }
        default {
            throw "Invalid selection"
        }
    }
}

function Get-TemplateList {
    param([string]$Strategy)
    
    if ($Strategy -eq "Aggregated") {
        return @("fabric-dataflow-aggregated.json")
    } else {
        return @(
            "fabric-dataflow-cnc.json",
            "fabric-dataflow-3dprinter.json",
            "fabric-dataflow-welding.json"
        )
    }
}

function Deploy-Dataflows {
    param(
        [string[]]$Templates,
        [object]$Config,
        [string]$CustomLocation,
        [string]$FabricTopicId
    )
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Deploying Dataflows via ARM" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    $operationsDir = Join-Path (Split-Path $script:ScriptDir) "operations\arm_templates"
    
    foreach ($template in $Templates) {
        $templatePath = Join-Path $operationsDir $template
        
        if (-not (Test-Path $templatePath)) {
            Write-WarnLog "Template not found: $templatePath"
            continue
        }
        
        $deploymentName = "dataflow-$($template -replace '.json$', '')-$(Get-Date -Format 'yyyyMMddHHmmss')"
        
        Write-InfoLog "Deploying: $template"
        
        try {
            az deployment group create `
                --resource-group $Config.azure.resource_group `
                --subscription $Config.azure.subscription_id `
                --name $deploymentName `
                --template-file $templatePath `
                --parameters `
                    customLocationName=$CustomLocation `
                    aioInstanceName=$Config.azure.aio_instance_name `
                    fabricTopicId=$FabricTopicId `
                --output table
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "$($template -replace '.json$', '') deployed"
            } else {
                Write-ErrorLog "Failed to deploy $template"
            }
        }
        catch {
            Write-ErrorLog "Error deploying $template : $_"
        }
        
        Write-Host ""
    }
    
    # Wait for dataflows to initialize
    Write-InfoLog "Waiting for dataflows to initialize..."
    Start-Sleep -Seconds 5
}

function Verify-Deployment {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Verification" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    Write-Host "Deployed Dataflows:" -ForegroundColor Cyan
    kubectl get dataflow -n azure-iot-operations -o wide
    
    Write-Host "`nDataflow Pods Status:" -ForegroundColor Cyan
    kubectl get pods -n azure-iot-operations -l app=aio-dataflow
    
    Write-Host "`nRecent Dataflow Logs:" -ForegroundColor Cyan
    $logs = kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=20 --max-log-requests=10 2>$null
    if ($LASTEXITCODE -eq 0 -and $logs) {
        Write-Host $logs
    } else {
        Write-WarnLog "Could not retrieve logs (pods may still be starting)"
    }
}

function Show-Summary {
    param([string]$FabricTopicId, [string]$ConfigFile)
    
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Deployment Complete!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
    
    Write-Host "Next Steps:"
    Write-Host "1. Verify dataflows are running:"
    Write-Host "   kubectl get dataflow -n azure-iot-operations"
    Write-Host ""
    Write-Host "2. Check for errors:"
    Write-Host "   kubectl logs -n azure-iot-operations -l app=aio-dataflow --tail=50"
    Write-Host ""
    Write-Host "3. Monitor MQTT traffic reaching Fabric:"
    Write-Host "   - Go to https://app.fabric.microsoft.com"
    Write-Host "   - Open your Eventstream"
    Write-Host "   - Check 'Data preview' for incoming messages"
    Write-Host ""
    Write-Host "4. Verify message rate matches edge telemetry (~2.16 msg/sec)"
    Write-Host ""
    
    if ($FabricTopicId -eq "es_YOUR_FABRIC_TOPIC_ID") {
        Write-Host "⚠ IMPORTANT: You used placeholder topic IDs." -ForegroundColor Yellow
        Write-Host "   Update linux_build/linux_aio_config.json with actual topic IDs:"
        Write-Host "   1. Get topic ID from Fabric portal: https://app.fabric.microsoft.com"
        Write-Host "   2. Edit: linux_build/linux_aio_config.json"
        Write-Host '   3. Update: "eventstream_topic_id": "es_YOUR_ACTUAL_TOPIC_ID"'
        Write-Host "   4. Re-run: .\Deploy-FabricDataflows.ps1"
        Write-Host ""
    }
    
    $duration = (Get-Date) - $script:StartTime
    Write-Host "Configuration file: $ConfigFile"
    Write-Host "Deployment completed in $([math]::Round($duration.TotalMinutes, 2)) minutes"
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
        Write-Host "Azure IoT Operations - Fabric Dataflow Deployment" -ForegroundColor Cyan
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Log file: $script:LogFile"
        Write-Host "Started: $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')"
        Write-Host "Script directory: $script:ScriptDir"
        Write-Host ""
        
        # Check prerequisites
        Test-Prerequisites
        Write-Host ""
        
        # Find and load configuration
        $configPath = Find-ConfigFile
        $config = Load-Configuration -ConfigFilePath $configPath
        
        # Get custom location
        $customLocation = Get-CustomLocation -Config $config
        Write-Host ""
        
        # Get Fabric configuration
        $fabricConfig = Get-FabricConfiguration -Config $config
        
        # Deploy Fabric endpoint
        Deploy-FabricEndpoint
        
        # Select deployment strategy
        $deploymentStrategy = Select-DeploymentStrategy
        Write-Host ""
        
        # Get template list based on strategy
        $templates = Get-TemplateList -Strategy $deploymentStrategy
        
        # Deploy dataflows
        Deploy-Dataflows `
            -Templates $templates `
            -Config $config `
            -CustomLocation $customLocation `
            -FabricTopicId $fabricConfig.TopicId
        
        # Verify deployment
        Verify-Deployment
        
        # Show summary
        Show-Summary -FabricTopicId $fabricConfig.TopicId -ConfigFile $configPath
        
        Write-Success "Fabric dataflow deployment completed successfully!"
        
    }
    catch {
        Write-ErrorLog "Deployment failed: $_"
        Write-ErrorLog $_.Exception.Message
        Write-ErrorLog "Stack Trace: $($_.ScriptStackTrace)"
        
        Write-Host "`n============================================================================" -ForegroundColor Red
        Write-Host "Fabric Dataflow Deployment Failed!" -ForegroundColor Red
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
