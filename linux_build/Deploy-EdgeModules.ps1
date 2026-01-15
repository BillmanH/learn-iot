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
    [ValidateSet("edgemqttsim", "hello-flask", "sputnik", "wasm-quality-filter-python", "demohistorian")]
    [string]$ModuleName,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipBuild,
    
    [Parameter(Mandatory=$false)]
    [string]$ImageTag = "latest"
)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script variables
$script:ScriptDir = $PSScriptRoot
$script:IotOppsDir = Join-Path (Split-Path $script:ScriptDir) "iotopps"
$script:LogFile = Join-Path $script:ScriptDir "deploy_edge_modules_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:StartTime = Get-Date
$script:ProxyJob = $null  # Store proxy job for cleanup
$script:ContainerRegistry = $null  # Container registry from config

#region Logging Functions

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] ${Level}: $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "INFO"    { Write-Host $logMessage -ForegroundColor Cyan }
        default   { Write-Host $logMessage }
    }
    
    # Note: Transcript already captures all output, no need for Add-Content
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

function Find-ClusterInfoFile {
    Write-InfoLog "Searching for cluster_info.json..."
    
    $searchPaths = @(
        (Join-Path $script:ScriptDir "edge_configs\cluster_info.json"),
        (Join-Path $script:ScriptDir "cluster_info.json")
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            Write-InfoLog "Checking: $path"
            Write-Success "Found cluster info at: $path"
            return $path
        }
    }
    
    throw "Cluster info file cluster_info.json not found. Run linux_installer.sh on edge device first."
}

function Load-ClusterInfo {
    param([string]$ClusterInfoPath)
    
    Write-InfoLog "Loading cluster information from: $ClusterInfoPath"
    
    $clusterInfo = Get-Content $ClusterInfoPath -Raw | ConvertFrom-Json
    
    Write-Host "`nCluster Information:"
    Write-Host "  Cluster Name: $($clusterInfo.cluster_name)"
    Write-Host "  Node Name: $($clusterInfo.node_name)"
    Write-Host "  Kubernetes Version: $($clusterInfo.kubernetes_version)"
    Write-Host ""
    
    return $clusterInfo
}

function Load-Configuration {
    param([string]$ConfigFilePath)
    
    Write-InfoLog "Loading configuration from: $ConfigFilePath"
    
    $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
    
    # Check if modules section exists, if not create default
    if (-not $config.PSObject.Properties['modules']) {
        Write-WarnLog "No modules section found in configuration, creating default"
        $modulesConfig = [PSCustomObject]@{
            edgemqttsim = $false
            "hello-flask" = $false
            sputnik = $false
            "wasm-quality-filter-python" = $false
        }
        $config | Add-Member -NotePropertyName "modules" -NotePropertyValue $modulesConfig -Force
    }
    
    # Check for container registry setting
    if ($config.azure.PSObject.Properties['container_registry'] -and $config.azure.container_registry) {
        $script:ContainerRegistry = $config.azure.container_registry
        Write-InfoLog "Container registry: $script:ContainerRegistry"
    } else {
        $script:ContainerRegistry = $null
        Write-WarnLog "No container_registry specified in config. Deployment files must have valid image names."
    }
    
    Write-Host "`nModules Configuration:"
    $moduleProperties = @($config.modules.PSObject.Properties)
    if ($moduleProperties.Count -eq 0) {
        Write-Host "  (No modules configured)" -ForegroundColor Gray
    } else {
        foreach ($module in $moduleProperties) {
            $status = if ($module.Value) { "ENABLED" } else { "disabled" }
            $color = if ($module.Value) { "Green" } else { "Gray" }
            Write-Host "  $($module.Name): " -NoNewline
            Write-Host $status -ForegroundColor $color
        }
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
        $kubectlVersion = kubectl version --client 2>$null | Select-Object -First 1
        if ($kubectlVersion) {
            Write-Success "kubectl found: $kubectlVersion"
        } else {
            throw "kubectl not found or not responding"
        }
    }
    catch {
        throw "kubectl is not installed or not in PATH. Install from: https://kubernetes.io/docs/tasks/tools/"
    }
    
    # Check Azure CLI (needed for Arc proxy)
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
    
    # Check iotopps directory
    if (-not (Test-Path $script:IotOppsDir)) {
        throw "iotopps directory not found: $script:IotOppsDir"
    }
    Write-Success "iotopps directory found: $script:IotOppsDir"
}

function Start-ArcProxy {
    param(
        [string]$ClusterName,
        [string]$ResourceGroup
    )
    
    Write-InfoLog "Starting Azure Arc proxy tunnel..."
    Write-InfoLog "Command: az connectedk8s proxy --name $ClusterName --resource-group $ResourceGroup"
    
    # Check if cluster is Arc-enabled
    $arcCluster = az connectedk8s show --name $ClusterName --resource-group $ResourceGroup 2>$null
    if (-not $arcCluster) {
        throw "Cluster $ClusterName is not Arc-enabled. Run External-Configurator.ps1 first."
    }
    Write-Success "Cluster is Arc-enabled"
    
    # Start proxy in background job
    Write-InfoLog "Starting Arc proxy in background (this may take 15-30 seconds)..."
    $proxyJob = Start-Job -ScriptBlock {
        param($clusterName, $resourceGroup)
        az connectedk8s proxy --name $clusterName --resource-group $resourceGroup 2>&1
    } -ArgumentList $ClusterName, $ResourceGroup
    
    # Wait for proxy to establish
    Write-InfoLog "Waiting for proxy tunnel to establish..."
    Start-Sleep -Seconds 25
    
    # Store for cleanup
    $script:ProxyJob = $proxyJob
    
    # Verify proxy is running
    Write-InfoLog "Checking proxy job status..."
    $jobState = $proxyJob.State
    Write-InfoLog "Proxy job state: $jobState"
    
    if ($jobState -ne "Running") {
        $proxyOutput = Receive-Job -Job $proxyJob 2>&1
        Write-ErrorLog "Proxy failed to start: $proxyOutput"
        throw "Arc proxy failed to start"
    }
    
    Write-Success "Arc proxy established"
}

function Test-ClusterConnection {
    Write-InfoLog "Testing cluster connection via Arc proxy..."
    
    try {
        $clusterInfo = kubectl cluster-info 2>&1
        if ($LASTEXITCODE -eq 0) {
            $currentContext = kubectl config current-context 2>$null
            Write-Success "Connected to cluster: $currentContext"
            Write-InfoLog "Connection is through Azure Arc proxy (cross-network)"
            return $true
        } else {
            return $false
        }
    }
    catch {
        return $false
    }
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
    
    # Check for deployment in default namespace (temporarily ignore errors for "not found" cases)
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    try {
        $deployment = kubectl get deployment -n default -l app=$Module 2>&1
        $exitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $previousErrorPref
        
        if ($exitCode -eq 0 -and $deployment -notmatch "No resources found") {
            Write-InfoLog "$Module deployment exists"
            return $true
        }
        
        Write-InfoLog "$Module is not currently deployed"
        return $false
    }
    catch {
        $ErrorActionPreference = $previousErrorPref
        return $false
    }
}

#endregion

#region Deployment Functions

function Build-AndPushContainer {
    param(
        [string]$Module,
        [string]$Registry,
        [string]$Tag
    )
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Building and Pushing Container" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $modulePath = Join-Path $script:IotOppsDir $Module
    
    if (-not (Test-Path (Join-Path $modulePath "Dockerfile"))) {
        throw "Dockerfile not found for module: $Module"
    }
    
    Write-InfoLog "Building container image..."
    $imageName = "$Registry/${Module}:$Tag"
    Write-InfoLog "Image: $imageName"
    Write-InfoLog "Context: $modulePath"
    
    # Build the image (allow docker's informational output)
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    $buildOutput = docker build -t $imageName $modulePath 2>&1
    $buildExitCode = $LASTEXITCODE
    
    $ErrorActionPreference = $previousErrorPref
    
    if ($buildExitCode -ne 0) {
        Write-ErrorLog "Docker build failed with exit code: $buildExitCode"
        $buildOutput | ForEach-Object { Write-ErrorLog $_ }
        
        # Check for common Docker Desktop issues on Windows
        if ($buildOutput -match "dockerDesktopLinuxEngine|The system cannot find the file specified|error during connect") {
            Write-ErrorLog ""
            Write-ErrorLog "============================================================"
            Write-ErrorLog "TROUBLESHOOTING: Docker Desktop may not be running"
            Write-ErrorLog "============================================================"
            Write-ErrorLog "This error typically occurs when Docker Desktop is not running on Windows."
            Write-ErrorLog ""
            Write-ErrorLog "To resolve this issue:"
            Write-ErrorLog "  1. Start Docker Desktop from the Start menu"
            Write-ErrorLog "  2. Wait for Docker to fully initialize (whale icon in system tray)"
            Write-ErrorLog "  3. Verify Docker is running with: docker ps"
            Write-ErrorLog "  4. Re-run this deployment script"
            Write-ErrorLog ""
            Write-ErrorLog "If Docker Desktop is running and you still see this error:"
            Write-ErrorLog "  - Restart Docker Desktop"
            Write-ErrorLog "  - Check if Docker is set to use Linux containers"
            Write-ErrorLog "  - Verify Docker Desktop is fully updated"
            Write-ErrorLog "============================================================"
            Write-ErrorLog ""
        }
        
        throw "Failed to build container image"
    }
    
    Write-Success "Container built successfully"
    
    # Push the image
    Write-InfoLog "Pushing image to registry: $Registry"
    
    $ErrorActionPreference = "Continue"
    $pushOutput = docker push $imageName 2>&1
    $pushExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorPref
    
    if ($pushExitCode -ne 0) {
        Write-ErrorLog "Docker push failed with exit code: $pushExitCode"
        $pushOutput | ForEach-Object { Write-ErrorLog $_ }
        throw "Failed to push container image"
    }
    
    Write-Success "Container pushed successfully: $imageName"
    return $imageName
}

function Update-DeploymentRegistry {
    param(
        [string]$DeploymentPath,
        [string]$Module
    )
    
    if (-not $script:ContainerRegistry) {
        Write-InfoLog "No container registry configured, using deployment.yaml as-is"
        return $DeploymentPath
    }
    
    Write-InfoLog "Updating deployment YAML with registry and namespace..."
    
    # Read deployment file
    $deploymentContent = Get-Content $DeploymentPath -Raw
    
    # Replace <YOUR_REGISTRY> placeholder with actual registry
    $updatedContent = $deploymentContent -replace '<YOUR_REGISTRY>', $script:ContainerRegistry
    
    # Update namespace to 'default' instead of 'azure-iot-operations'
    $updatedContent = $updatedContent -replace 'namespace:\s*azure-iot-operations', 'namespace: default'
    
    # Create temp file with updated content
    $tempPath = Join-Path $env:TEMP "$Module-deployment-$(Get-Date -Format 'yyyyMMddHHmmss').yaml"
    $updatedContent | Set-Content -Path $tempPath -Encoding UTF8
    
    Write-InfoLog "Created temporary deployment file: $tempPath"
    Write-InfoLog "Target namespace: default"
    return $tempPath
}

function Ensure-ServiceAccount {
    param(
        [string]$ServiceAccountName = "mqtt-client",
        [string]$Namespace = "default"
    )
    
    Write-InfoLog "Checking if service account '$ServiceAccountName' exists in namespace '$Namespace'..."
    
    # Check if service account exists
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    try {
        $saExists = kubectl get serviceaccount $ServiceAccountName -n $Namespace 2>&1
        $exitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $previousErrorPref
        
        if ($exitCode -eq 0 -and $saExists -notmatch "NotFound" -and $saExists -notmatch "No resources found") {
            Write-Success "Service account '$ServiceAccountName' already exists"
            return $true
        }
        
        # Create the service account
        Write-InfoLog "Creating service account '$ServiceAccountName' in namespace '$Namespace'..."
        kubectl create serviceaccount $ServiceAccountName -n $Namespace 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Service account '$ServiceAccountName' created successfully"
            return $true
        } else {
            Write-ErrorLog "Failed to create service account '$ServiceAccountName'"
            return $false
        }
    }
    catch {
        $ErrorActionPreference = $previousErrorPref
        Write-ErrorLog "Error checking/creating service account: $_"
        return $false
    }
}

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
        kubectl delete deployment -n default -l app=$Module 2>$null
        Start-Sleep -Seconds 3
    }
    
    # Update deployment file with container registry if configured
    $deploymentPath = Update-DeploymentRegistry -DeploymentPath $moduleCheck.Path -Module $Module
    
    # Deploy using kubectl
    Write-InfoLog "Applying deployment.yaml for $Module..."
    Write-InfoLog "Path: $deploymentPath"
    Write-InfoLog "Using kubectl through Azure Arc proxy (cross-network)"
    
    $deployResult = kubectl apply -f $deploymentPath 2>&1
    
    # Clean up temp file if it was created
    if ($deploymentPath -ne $moduleCheck.Path -and (Test-Path $deploymentPath)) {
        Remove-Item $deploymentPath -Force -ErrorAction SilentlyContinue
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "$Module deployment applied successfully"
        
        # Wait for pod to be ready
        Write-InfoLog "Waiting for pod to be ready (timeout: 60s)..."
        $timeout = 60
        $elapsed = 0
        $ready = $false
        
        # Temporarily allow errors for kubectl commands
        $previousErrorPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        
        while ($elapsed -lt $timeout) {
            # Check if any pods exist first
            $podCount = kubectl get pods -n default -l app=$Module --no-headers 2>&1 | Measure-Object | Select-Object -ExpandProperty Count
            
            if ($podCount -gt 0) {
                # Now safely check the pod status
                $pod = kubectl get pods -n default -l app=$Module -o jsonpath='{.items[0].status.phase}' 2>&1
                if ($pod -eq "Running") {
                    $ErrorActionPreference = $previousErrorPref
                    Write-Success "$Module pod is running"
                    $ready = $true
                    break
                }
            }
            
            Start-Sleep -Seconds 2
            $elapsed += 2
            Write-Host "." -NoNewline
        }
        Write-Host ""
        
        $ErrorActionPreference = $previousErrorPref
        
        if (-not $ready) {
            Write-WarnLog "$Module pod did not become ready within timeout"
            Write-InfoLog "Check status with: kubectl get pods -n default -l app=$Module"
        }
        
        # Show pod status
        Write-InfoLog "Current pod status:"
        kubectl get pods -n default -l app=$Module
        
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
    
    if (@($modules).Count -eq 0) {
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
    
    Write-InfoLog "All deployments in default namespace:"
    kubectl get deployments -n default
    
    Write-Host "`nPods:" -ForegroundColor Cyan
    kubectl get pods -n default
    
    Write-Host "`nServices:" -ForegroundColor Cyan
    kubectl get services -n default
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
    Write-Host "   kubectl logs -n default -l app=<module-name>"
    Write-Host ""
    Write-Host "2. Monitor module status:"
    Write-Host "   kubectl get pods -n default -w"
    Write-Host ""
    Write-Host "3. View module output (for MQTT modules):"
    Write-Host "   kubectl logs -n default -l app=edgemqttsim -f"
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
        
        # Find and load cluster info (for cluster name)
        Write-InfoLog "Loading cluster information..."
        $clusterInfoPath = Find-ClusterInfoFile
        $clusterInfo = Load-ClusterInfo -ClusterInfoPath $clusterInfoPath
        $script:ClusterName = $clusterInfo.cluster_name
        
        # Find and load Azure config (for resource group and subscription)
        Write-InfoLog "Loading Azure configuration..."
        $configPath = Find-ConfigFile
        $config = Load-Configuration -ConfigFilePath $configPath
        
        # Extract Azure settings from config file
        $script:ResourceGroup = $config.azure.resource_group
        $script:SubscriptionId = $config.azure.subscription_id
        
        Write-Host "`nConfiguration Summary:"
        Write-Host "  Subscription: $script:SubscriptionId"
        Write-Host "  Resource Group: $script:ResourceGroup"
        Write-Host "  Cluster Name: $script:ClusterName"
        Write-Host "  Node: $($clusterInfo.node_name)"
        Write-Host ""
        
        # Get modules to deploy
        $modulesToDeploy = @(Get-ModulesToDeploy -Config $config)
        
        if ($modulesToDeploy.Count -eq 0) {
            Write-WarnLog "No modules to deploy"
            Write-Host "Update linux_aio_config.json modules section to enable modules"
            exit 0
        }
        
        # Build and push containers BEFORE starting Arc proxy
        if (-not $SkipBuild -and $script:ContainerRegistry) {
            Write-Host "`n========================================" -ForegroundColor Cyan
            Write-Host "Building and Pushing Containers" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            
            foreach ($module in $modulesToDeploy) {
                try {
                    Build-AndPushContainer -Module $module -Registry $script:ContainerRegistry -Tag $ImageTag
                }
                catch {
                    Write-ErrorLog "Failed to build/push $module : $_"
                    throw "Container build failed for $module"
                }
            }
        } elseif (-not $script:ContainerRegistry) {
            Write-WarnLog "No container registry configured - assuming images already exist in registry"
        } else {
            Write-InfoLog "Skipping container build (using existing images)"
        }
        
        # Start Arc proxy for kubectl connectivity
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Establishing Arc Proxy Connection" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Start-ArcProxy -ClusterName $script:ClusterName -ResourceGroup $script:ResourceGroup
        
        # Test connection
        $connected = Test-ClusterConnection
        if (-not $connected) {
            throw "Failed to connect to cluster through Arc proxy"
        }
        Write-Host ""
        
        # Ensure mqtt-client service account exists
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Ensuring Service Account" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        $saResult = Ensure-ServiceAccount -ServiceAccountName "mqtt-client" -Namespace "default"
        if (-not $saResult) {
            Write-WarnLog "Failed to create service account - deployments may fail if they require it"
        }
        Write-Host ""
        
        # Deploy each module (containers already built and pushed)
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
        # Cleanup Arc proxy job if it was started
        if ($script:ProxyJob) {
            Write-InfoLog "Stopping Arc proxy job..."
            Stop-Job -Job $script:ProxyJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:ProxyJob -ErrorAction SilentlyContinue
        }
        
        Stop-Transcript
    }
}

# Execute main function
Main

#endregion
