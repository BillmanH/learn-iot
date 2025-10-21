<#
.SYNOPSIS
    Check status of application deployed to IoT Edge cluster
.DESCRIPTION
    Connects to your Arc-enabled IoT Operations cluster and displays
    the current status of the specified application deployment.
.PARAMETER AppFolder
    Name of the application folder under iotopps (e.g., 'hello-flask')
.PARAMETER ConfigPath
    Path to the configuration JSON file
.PARAMETER EdgeDeviceIP
    Optional: Direct connection to edge device IP
.EXAMPLE
    .\Deploy-Check.ps1 -AppFolder "hello-flask"
.EXAMPLE
    .\Deploy-Check.ps1 -AppFolder "my-app" -EdgeDeviceIP "192.168.1.100"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AppFolder,
    
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\..\linux_build\linux_aio_config.json",
    
    [Parameter()]
    [string]$EdgeDeviceIP
)

$ErrorActionPreference = 'Stop'

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n" -NoNewline
    Write-ColorOutput "=== $Title ===" -Color Cyan
}

# Validate app folder
$appPath = Join-Path $PSScriptRoot $AppFolder
if (-not (Test-Path $appPath)) {
    Write-ColorOutput "[ERROR] Application folder not found: $appPath" -Color Red
    Write-Host "Available applications in iotopps:"
    Get-ChildItem $PSScriptRoot -Directory | ForEach-Object { Write-Host "  - $($_.Name)" }
    exit 1
}

# Try to load app-specific config
$appConfigPath = Join-Path $appPath "$($AppFolder)_config.json"
if (Test-Path $appConfigPath) {
    try {
        $appConfig = Get-Content $appConfigPath -Raw | ConvertFrom-Json
        Write-ColorOutput "Loaded app config: $appConfigPath" -Color Green
    } catch {
        Write-ColorOutput "Warning: Could not parse app config: $_" -Color Yellow
    }
}

# Banner
Write-ColorOutput @"

===============================================================
   IoT Edge Deployment - Status Check
   Application: $AppFolder
===============================================================

"@ -Color Cyan

# Load configuration
if (Test-Path $ConfigPath) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $clusterName = $config.azure.cluster_name
    $resourceGroup = $config.azure.resource_group
    
    Write-Host "Configuration loaded from: $ConfigPath"
    Write-Host "  Cluster: $clusterName"
    Write-Host "  Resource Group: $resourceGroup"
    Write-Host "  Application: $AppFolder"
} else {
    Write-ColorOutput "Warning: Configuration file not found: $ConfigPath" -Color Yellow
    Write-Host "Proceeding with current kubectl context..."
}

# Check Docker login status
Write-Section "Docker Authentication"
try {
    $dockerInfo = docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        # Check if logged in by looking for registry info
        $dockerConfigPath = "$env:USERPROFILE\.docker\config.json"
        if (Test-Path $dockerConfigPath) {
            $dockerConfig = Get-Content $dockerConfigPath -Raw | ConvertFrom-Json
            if ($dockerConfig.auths -and ($dockerConfig.auths.PSObject.Properties.Count -gt 0)) {
                Write-ColorOutput "[OK] Docker is authenticated" -Color Green
                $dockerConfig.auths.PSObject.Properties.Name | ForEach-Object {
                    Write-Host "  Registry: $_"
                }
            } else {
                Write-ColorOutput "[INFO] Docker is running but no registry authentication found" -Color Yellow
                Write-Host "  Run 'docker login' if you need to push images"
            }
        } else {
            Write-ColorOutput "[INFO] Docker is running" -Color White
        }
    } else {
        Write-ColorOutput "[INFO] Docker is not running (only needed for building/pushing images)" -Color White
    }
} catch {
    Write-ColorOutput "[INFO] Docker not available (only needed for building/pushing images)" -Color White
    Write-Host "  If you need to build images, install Docker on this machine"
    Write-Host "  or use a machine with Docker and push to a container registry"
}

# Check cluster connectivity
Write-Section "Cluster Connection"

if ($config) {
    Write-ColorOutput "`nPlease start the cluster proxy in another terminal window:" -Color Yellow
    Write-ColorOutput "  az connectedk8s proxy -n $clusterName -g $resourceGroup" -Color White
    Write-Host "`nPress any key once you see 'Proxy is listening on port...' and 'Start sending kubectl requests...'" -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
}

Write-Host "Verifying cluster connection..."
$nodeOutput = kubectl get nodes 2>&1
$nodeExitCode = $LASTEXITCODE

if ($nodeExitCode -eq 0) {
    Write-ColorOutput "[OK] Connected to cluster" -Color Green
    Write-Host $nodeOutput
} else {
    Write-ColorOutput "[WARNING] Could not connect to get nodes (this may be OK)" -Color Yellow
    Write-Host "Error details: $nodeOutput"
    Write-Host "`nAttempting to continue with deployment checks..."
}

# Check deployments
Write-Section "Deployment Status"

$ErrorActionPreference = 'SilentlyContinue'
$deploymentOutput = kubectl get deployment $AppFolder 2>&1 | Out-String
$deploymentExitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'

if ($deploymentExitCode -eq 0) {
    Write-Host $deploymentOutput
    Write-ColorOutput "[OK] Deployment exists" -Color Green
} else {
    Write-ColorOutput "[INFO] Deployment '$AppFolder' not found" -Color Yellow
    Write-Host "`nTo deploy the application, run: .\Deploy-ToIoTEdge.ps1 -AppFolder '$AppFolder'"
}

# Check pods
Write-Section "Pod Status"
$pods = kubectl get pods -l app=$AppFolder --no-headers 2>&1
if ($LASTEXITCODE -eq 0 -and $pods) {
    kubectl get pods -l app=$AppFolder
    
    $podStatus = ($pods -split '\s+')[2]
    if ($podStatus -eq "Running") {
        Write-ColorOutput "`n[OK] Pod is running" -Color Green
    } else {
        Write-ColorOutput "`n[WARNING] Pod status: $podStatus" -Color Yellow
        
        # Get pod name for logs
        $podName = ($pods -split '\s+')[0]
        Write-Host "`nRecent logs:"
        kubectl logs $podName --tail=20
    }
} else {
    Write-ColorOutput "[ERROR] No pods found" -Color Red
}

# Check service
Write-Section "Service Status"
$serviceName = "$AppFolder-service"
try {
    kubectl get service $serviceName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        kubectl get service $serviceName
        
        $nodePort = kubectl get service $serviceName -o jsonpath='{.spec.ports[0].nodePort}' 2>&1
        
        if ($EdgeDeviceIP) {
            $serviceUrl = "http://${EdgeDeviceIP}:${nodePort}"
        } else {
            $nodeIP = kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>&1
            if ($nodeIP) {
                $serviceUrl = "http://${nodeIP}:${nodePort}"
            }
        }
        
        Write-ColorOutput "`n[OK] Service is exposed" -Color Green
        if ($serviceUrl) {
            Write-Host "Service URL: $serviceUrl"
        }
    } else {
        Write-ColorOutput "[ERROR] Service not found" -Color Red
    }
} catch {
    Write-ColorOutput "[WARNING] Error checking service: $_" -Color Yellow
}

# Test endpoint if possible
if ($serviceUrl) {
    Write-Section "Connectivity Test"
    Write-Host "Testing endpoint: $serviceUrl"
    
    try {
        $response = Invoke-WebRequest -Uri $serviceUrl -TimeoutSec 5 -UseBasicParsing
        if ($response.StatusCode -eq 200) {
            Write-ColorOutput "[OK] Application is responding!" -Color Green
            Write-Host "Response:"
            Write-Host $response.Content
        }
    } catch {
        Write-ColorOutput "[ERROR] Cannot reach application endpoint" -Color Red
        Write-Host "This may be normal if:"
        Write-Host "  - You're not on the same network as the edge device"
        Write-Host "  - Firewall is blocking port $nodePort"
        Write-Host "  - Pod is still starting up"
    }
}

# Show recent events
Write-Section "Recent Events"
kubectl get events --field-selector involvedObject.name=$AppFolder --sort-by='.lastTimestamp' | Select-Object -Last 10

# Summary
Write-Section "Summary"

# Check deployment readiness
try {
    $deploymentStatus = kubectl get deployment $AppFolder -o jsonpath="{.status.conditions[?(@.type=='Available')].status}" 2>&1
    $deploymentReady = ($deploymentStatus -eq "True")
} catch {
    $deploymentReady = $false
}

# Check pod readiness
try {
    $podStatus = kubectl get pods -l app=$AppFolder -o jsonpath="{.items[0].status.conditions[?(@.type=='Ready')].status}" 2>&1
    $podsReady = ($podStatus -eq "True")
} catch {
    $podsReady = $false
}

# Check service
$serviceExists = $false
try {
    kubectl get service $serviceName 2>&1 | Out-Null
    $serviceExists = ($LASTEXITCODE -eq 0)
} catch {
    $serviceExists = $false
}

# Final status display
Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "                    DEPLOYMENT STATUS" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan

if ($deploymentReady -and $podsReady -and $serviceExists) {
    Write-Host ""
    Write-ColorOutput "  [OK] Deployment:     READY" -Color Green
    Write-ColorOutput "  [OK] Pods:           RUNNING" -Color Green
    Write-ColorOutput "  [OK] Service:        EXPOSED" -Color Green
    Write-Host ""
    Write-ColorOutput "  >> ALL SYSTEMS OPERATIONAL! <<" -Color Green
    Write-Host ""
    
    if ($serviceUrl) {
        Write-ColorOutput "  Application URL: $serviceUrl" -Color Cyan
        Write-Host ""
    }
    
    Write-ColorOutput "  Your application '$AppFolder' is successfully deployed and ready!" -Color White
    Write-Host ""
} elseif ($deploymentReady -and $podsReady) {
    Write-Host ""
    Write-ColorOutput "  [OK] Deployment:     READY" -Color Green
    Write-ColorOutput "  [OK] Pods:           RUNNING" -Color Green
    Write-ColorOutput "  [WARNING] Service:   CHECK REQUIRED" -Color Yellow
    Write-Host ""
    Write-ColorOutput "  >> DEPLOYMENT PARTIALLY READY <<" -Color Yellow
    Write-Host ""
} elseif ($deploymentReady) {
    Write-Host ""
    Write-ColorOutput "  [OK] Deployment:     EXISTS" -Color Green
    Write-ColorOutput "  [WARNING] Pods:      NOT READY" -Color Yellow
    if ($serviceExists) {
        Write-ColorOutput "  [OK] Service:        EXPOSED" -Color Green
    } else {
        Write-ColorOutput "  [ERROR] Service:     NOT FOUND" -Color Red
    }
    Write-Host ""
    Write-ColorOutput "  >> PODS NOT READY - Check logs for issues <<" -Color Yellow
    Write-Host ""
} else {
    Write-Host ""
    Write-ColorOutput "  [ERROR] Deployment:  NOT FOUND" -Color Red
    Write-ColorOutput "  [ERROR] Pods:        NONE" -Color Red
    Write-ColorOutput "  [ERROR] Service:     N/A" -Color Red
    Write-Host ""
    Write-ColorOutput "  >> APPLICATION NOT DEPLOYED <<" -Color Red
    Write-Host ""
    Write-Host "  Next Step: Run .\Deploy-ToIoTEdge.ps1 -AppFolder '$AppFolder' to deploy the application" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "===============================================================" -ForegroundColor Cyan

Write-Host "`nUseful Commands:"
Write-Host "  View logs:           kubectl logs -l app=$AppFolder --tail=50"
Write-Host "  Follow logs:         kubectl logs -l app=$AppFolder -f"
Write-Host "  Describe pod:        kubectl describe pod <pod-name>"
Write-Host "  Restart deployment:  kubectl rollout restart deployment/$AppFolder"
Write-Host "  Delete deployment:   kubectl delete -f $AppFolder/deployment.yaml"

if ($serviceUrl) {
    Write-Host "`nTest Application:"
    Write-Host "  curl $serviceUrl"
    Write-Host "  curl $serviceUrl/health"
}

Write-Host ""
