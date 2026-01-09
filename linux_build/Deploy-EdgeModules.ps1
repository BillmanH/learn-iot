<#
.SYNOPSIS
    Deploy edge modules to Azure IoT Operations cluster via kubectl
.DESCRIPTION
    This script deploys edge modules (edgemqttsim, hello-flask, sputnik, wasm-quality-filter-python)
    to the Kubernetes cluster using kubectl through Azure Arc proxy. Runs remotely from Windows
    to edge device on different network.
.PARAMETER ConfigPath
    Path to linux_aio_config.json. If not specified, searches in edge_configs/ or current directory.
.PARAMETER ModuleName
    Specific module to deploy. If not specified, deploys all modules marked true in config.
.PARAMETER Force
    Force redeployment even if module is already running
.EXAMPLE
    .\Deploy-EdgeModules.ps1
.EXAMPLE
    .\Deploy-EdgeModules.ps1 -ModuleName edgemqttsim
.EXAMPLE
    .\Deploy-EdgeModules.ps1 -ModuleName hello-flask -Force
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("edgemqttsim", "hello-flask", "sputnik", "wasm-quality-filter-python")]
    [string]$ModuleName,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script variables
$script:ScriptDir = $PSScriptRoot
$script:IotOppsDir = Join-Path (Split-Path $script:ScriptDir) "iotopps"
$script:LogFile = Join-Path $script:ScriptDir "deploy_edge_modules_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
    
    if (-not $config.modules) {
        Write-WarnLog "No modules section found in configuration"
        $config | Add-Member -NotePropertyName "modules" -NotePropertyValue @{} -Force
    }
    
    Write-Host "`nModules Configuration:"
    foreach ($module in $config.modules.PSObject.Properties) {
        $status = if ($module.Value) { "ENABLED" } else { "disabled" }
        $color = if ($module.Value) { "Green" } else { "Gray" }
        Write-Host "  $($module.Name): " -NoNewline
        Write-Host $status -ForegroundColor $color
    }
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
    
    # Check cluster connection
    Write-InfoLog "Checking cluster connection via Arc proxy..."
    try {
        $clusterInfo = kubectl cluster-info 2>&1
        if ($LASTEXITCODE -eq 0) {
            $currentContext = kubectl config current-context 2>$null
            Write-Success "Connected to cluster: $currentContext"
            Write-InfoLog "Connection is through Azure Arc proxy (cross-network)"
        } else {
            throw "Not connected to Kubernetes cluster"
        }
    }
    catch {
        throw "Cannot connect to Kubernetes cluster. Run External-Configurator.ps1 first to establish Arc proxy."
    }
    
    # Check iotopps directory
    if (-not (Test-Path $script:IotOppsDir)) {
        throw "iotopps directory not found: $script:IotOppsDir"
    }
    Write-Success "iotopps directory found: $script:IotOppsDir"
}

function Test-ModuleExists {
    param([string]$Module)
    
    $modulePath = Join-Path $script:IotOppsDir $Module
    $deploymentPath = Join-Path $modulePath "deployment.yaml"
    
    if (-not (Test-Path $modulePath)) {
        return @{ Exists = $false; Reason = "Module directory not found" }
    }
    
    if (-not (Test-Path $deploymentPath)) {
        return @{ Exists = $false; Reason = "deployment.yaml not found" }
    }
    
    return @{ Exists = $true; Path = $deploymentPath }
}

function Test-ModuleDeployed {
    param([string]$Module)
    
    Write-InfoLog "Checking if $Module is already deployed..."
    
    # Check for deployment
    $deployment = kubectl get deployment -n azure-iot-operations -l app=$Module 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-InfoLog "$Module deployment exists"
        return $true
    }
    
    return $false
}

#endregion

#region Deployment Functions

function Deploy-Module {
    param(
        [string]$Module,
        [bool]$ForceRedeploy = $false
    )
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Deploying Module: $Module" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Check if module exists
    $moduleCheck = Test-ModuleExists -Module $Module
    if (-not $moduleCheck.Exists) {
        Write-ErrorLog "Cannot deploy $Module : $($moduleCheck.Reason)"
        return $false
    }
    
    # Check if already deployed
    $isDeployed = Test-ModuleDeployed -Module $Module
    if ($isDeployed -and -not $ForceRedeploy) {
        Write-WarnLog "$Module is already deployed. Use -Force to redeploy."
        return $true
    }
    
    if ($isDeployed -and $ForceRedeploy) {
        Write-InfoLog "Force redeployment requested, deleting existing deployment..."
        kubectl delete deployment -n azure-iot-operations -l app=$Module 2>$null
        Start-Sleep -Seconds 3
    }
    
    # Deploy using kubectl
    Write-InfoLog "Applying deployment.yaml for $Module..."
    Write-InfoLog "Path: $($moduleCheck.Path)"
    Write-InfoLog "Using kubectl through Azure Arc proxy (cross-network)"
    
    $deployResult = kubectl apply -f $moduleCheck.Path 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "$Module deployment applied successfully"
        
        # Wait for pod to be ready
        Write-InfoLog "Waiting for pod to be ready (timeout: 60s)..."
        $timeout = 60
        $elapsed = 0
        $ready = $false
        
        while ($elapsed -lt $timeout) {
            $pod = kubectl get pods -n azure-iot-operations -l app=$Module -o jsonpath='{.items[0].status.phase}' 2>$null
            if ($pod -eq "Running") {
                Write-Success "$Module pod is running"
                $ready = $true
                break
            }
            Start-Sleep -Seconds 2
            $elapsed += 2
            Write-Host "." -NoNewline
        }
        Write-Host ""
        
        if (-not $ready) {
            Write-WarnLog "$Module pod did not become ready within timeout"
            Write-InfoLog "Check status with: kubectl get pods -n azure-iot-operations -l app=$Module"
        }
        
        # Show pod status
        Write-InfoLog "Current pod status:"
        kubectl get pods -n azure-iot-operations -l app=$Module
        
        return $true
    } else {
        Write-ErrorLog "Failed to deploy $Module"
        Write-ErrorLog $deployResult
        return $false
    }
}

function Get-ModulesToDeploy {
    param([object]$Config)
    
    if ($ModuleName) {
        Write-InfoLog "Deploying specific module: $ModuleName"
        return @($ModuleName)
    }
    
    $modules = @()
    foreach ($module in $Config.modules.PSObject.Properties) {
        if ($module.Value -eq $true) {
            $modules += $module.Name
        }
    }
    
    if ($modules.Count -eq 0) {
        Write-WarnLog "No modules enabled in configuration"
    } else {
        Write-InfoLog "Modules to deploy: $($modules -join ', ')"
    }
    
    return $modules
}

function Show-DeploymentStatus {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Deployment Status" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    Write-InfoLog "All deployments in azure-iot-operations namespace:"
    kubectl get deployments -n azure-iot-operations
    
    Write-Host "`nPods:" -ForegroundColor Cyan
    kubectl get pods -n azure-iot-operations
    
    Write-Host "`nServices:" -ForegroundColor Cyan
    kubectl get services -n azure-iot-operations
}

function Show-Summary {
    param(
        [int]$Successful,
        [int]$Failed,
        [int]$Total
    )
    
    Write-Host "`n============================================================================" -ForegroundColor Green
    Write-Host "Edge Module Deployment Summary" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    
    Write-Host "`nResults:"
    Write-Host "  Total modules: $Total"
    Write-Host "  Successful: $Successful" -ForegroundColor Green
    if ($Failed -gt 0) {
        Write-Host "  Failed: $Failed" -ForegroundColor Red
    }
    
    $duration = (Get-Date) - $script:StartTime
    Write-Host "`nDeployment completed in $([math]::Round($duration.TotalMinutes, 2)) minutes"
    Write-Host "Log file: $script:LogFile"
    
    Write-Host "`nNext Steps:"
    Write-Host "1. Check pod logs:"
    Write-Host "   kubectl logs -n azure-iot-operations -l app=<module-name>"
    Write-Host ""
    Write-Host "2. Monitor module status:"
    Write-Host "   kubectl get pods -n azure-iot-operations -w"
    Write-Host ""
    Write-Host "3. View module output (for MQTT modules):"
    Write-Host "   kubectl logs -n azure-iot-operations -l app=edgemqttsim -f"
    Write-Host ""
    
    Write-InfoLog "Deployment completed via Azure Arc proxy (Windows -> Linux cross-network)"
    Write-Host ""
}

#endregion

#region Main Execution

function Main {
    try {
        # Start transcript
        Start-Transcript -Path $script:LogFile -Append
        
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Azure IoT Operations - Edge Module Deployment" -ForegroundColor Cyan
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Log file: $script:LogFile"
        Write-Host "Started: $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')"
        Write-Host ""
        Write-Host "NOTE: This script uses kubectl through Azure Arc proxy" -ForegroundColor Yellow
        Write-Host "      Supports cross-network deployment (Windows -> Linux)" -ForegroundColor Yellow
        Write-Host ""
        
        # Check prerequisites
        Test-Prerequisites
        Write-Host ""
        
        # Find and load configuration
        $configPath = Find-ConfigFile
        $config = Load-Configuration -ConfigFilePath $configPath
        
        # Get modules to deploy
        $modulesToDeploy = Get-ModulesToDeploy -Config $config
        
        if ($modulesToDeploy.Count -eq 0) {
            Write-WarnLog "No modules to deploy"
            Write-Host "Update linux_aio_config.json modules section to enable modules"
            exit 0
        }
        
        # Deploy each module
        $successful = 0
        $failed = 0
        
        foreach ($module in $modulesToDeploy) {
            $result = Deploy-Module -Module $module -ForceRedeploy $Force
            if ($result) {
                $successful++
            } else {
                $failed++
            }
        }
        
        # Show final status
        Show-DeploymentStatus
        
        # Show summary
        Show-Summary -Successful $successful -Failed $failed -Total $modulesToDeploy.Count
        
        if ($failed -gt 0) {
            Write-WarnLog "Some modules failed to deploy. Check logs for details."
            exit 1
        }
        
        Write-Success "All edge modules deployed successfully!"
        
    }
    catch {
        Write-ErrorLog "Deployment failed: $_"
        Write-ErrorLog $_.Exception.Message
        Write-ErrorLog "Stack Trace: $($_.ScriptStackTrace)"
        
        Write-Host "`n============================================================================" -ForegroundColor Red
        Write-Host "Edge Module Deployment Failed!" -ForegroundColor Red
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
