<#
.SYNOPSIS
    Check status of Flask application deployed to IoT Edge cluster
.DESCRIPTION
    Connects to your Arc-enabled IoT Operations cluster and displays
    the current status of the hello-flask deployment.
.PARAMETER ConfigPath
    Path to the configuration JSON file
.PARAMETER EdgeDeviceIP
    Optional: Direct connection to edge device IP
.EXAMPLE
    .\Deploy-Check.ps1
.EXAMPLE
    .\Deploy-Check.ps1 -EdgeDeviceIP "192.168.1.100"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\..\..\linux_build\linux_aio_config.json",
    
    [Parameter()]
    [string]$HelloFlaskConfigPath = "$PSScriptRoot\hello_flask_config.json",
    
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
    Write-ColorOutput "═══ $Title ═══" -Color Cyan
}

# Banner
Write-ColorOutput @"

╔═══════════════════════════════════════════════════════════╗
║        Flask IoT Edge - Deployment Status Check          ║
╚═══════════════════════════════════════════════════════════╝

"@ -Color Cyan

# Load configuration
if (Test-Path $ConfigPath) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $clusterName = $config.azure.cluster_name
    $resourceGroup = $config.azure.resource_group
    
    Write-Host "Configuration loaded from: $ConfigPath"
    Write-Host "  Cluster: $clusterName"
    Write-Host "  Resource Group: $resourceGroup"
} else {
    Write-ColorOutput "Warning: Configuration file not found: $ConfigPath" -Color Yellow
    Write-Host "Proceeding with current kubectl context..."
}

# Check cluster connectivity
Write-Section "Cluster Connection"
try {
    if ($config) {
        Write-Host "Connecting to Arc cluster..."
        Start-Process -FilePath "az" -ArgumentList "connectedk8s","proxy","-n",$clusterName,"-g",$resourceGroup -NoNewWindow
        Start-Sleep -Seconds 3
    }
    
    kubectl get nodes --no-headers 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "✓ Connected to cluster" -Color Green
        kubectl get nodes
    } else {
        throw "Connection failed"
    }
} catch {
    Write-ColorOutput "✗ Cannot connect to cluster" -Color Red
    Write-Host "Try running: az connectedk8s proxy -n $clusterName -g $resourceGroup"
    exit 1
}

# Check deployments
Write-Section "Deployment Status"
try {
    kubectl get deployment hello-flask 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        kubectl get deployment hello-flask
        Write-ColorOutput "`n✓ Deployment exists" -Color Green
    } else {
        Write-ColorOutput "✗ Deployment 'hello-flask' not found" -Color Red
        Write-Host "Run Deploy-ToIoTEdge.ps1 to deploy the application"
        exit 1
    }
} catch {
    Write-ColorOutput "✗ Error checking deployment: $_" -Color Red
    exit 1
}

# Check pods
Write-Section "Pod Status"
$pods = kubectl get pods -l app=hello-flask --no-headers 2>&1
if ($LASTEXITCODE -eq 0 -and $pods) {
    kubectl get pods -l app=hello-flask
    
    $podStatus = ($pods -split '\s+')[2]
    if ($podStatus -eq "Running") {
        Write-ColorOutput "`n✓ Pod is running" -Color Green
    } else {
        Write-ColorOutput "`n⚠ Pod status: $podStatus" -Color Yellow
        
        # Get pod name for logs
        $podName = ($pods -split '\s+')[0]
        Write-Host "`nRecent logs:"
        kubectl logs $podName --tail=20
    }
} else {
    Write-ColorOutput "✗ No pods found" -Color Red
}

# Check service
Write-Section "Service Status"
try {
    kubectl get service hello-flask-service 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        kubectl get service hello-flask-service
        
        $nodePort = kubectl get service hello-flask-service -o jsonpath='{.spec.ports[0].nodePort}' 2>&1
        
        if ($EdgeDeviceIP) {
            $serviceUrl = "http://${EdgeDeviceIP}:${nodePort}"
        } else {
            $nodeIP = kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>&1
            if ($nodeIP) {
                $serviceUrl = "http://${nodeIP}:${nodePort}"
            }
        }
        
        Write-ColorOutput "`n✓ Service is exposed" -Color Green
        if ($serviceUrl) {
            Write-Host "Service URL: $serviceUrl"
        }
    } else {
        Write-ColorOutput "✗ Service not found" -Color Red
    }
} catch {
    Write-ColorOutput "⚠ Error checking service: $_" -Color Yellow
}

# Test endpoint if possible
if ($serviceUrl) {
    Write-Section "Connectivity Test"
    Write-Host "Testing endpoint: $serviceUrl"
    
    try {
        $response = Invoke-WebRequest -Uri $serviceUrl -TimeoutSec 5 -UseBasicParsing
        if ($response.StatusCode -eq 200) {
            Write-ColorOutput "✓ Application is responding!" -Color Green
            Write-Host "Response:"
            $response.Content | ConvertFrom-Json | ConvertTo-Json
        }
    } catch {
        Write-ColorOutput "✗ Cannot reach application endpoint" -Color Red
        Write-Host "This may be normal if:"
        Write-Host "  - You're not on the same network as the edge device"
        Write-Host "  - Firewall is blocking port $nodePort"
        Write-Host "  - Pod is still starting up"
    }
}

# Show recent events
Write-Section "Recent Events"
kubectl get events --field-selector involvedObject.name=hello-flask --sort-by='.lastTimestamp' | Select-Object -Last 10

# Summary
Write-Section "Summary"
$deploymentReady = (kubectl get deployment hello-flask -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>&1) -eq "True"
$podsReady = (kubectl get pods -l app=hello-flask -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1) -eq "True"

if ($deploymentReady -and $podsReady) {
    Write-ColorOutput "`n✓ Application is HEALTHY and READY" -Color Green
} elseif ($deploymentReady) {
    Write-ColorOutput "`n⚠ Deployment exists but pods may not be ready" -Color Yellow
} else {
    Write-ColorOutput "`n✗ Application has issues" -Color Red
}

Write-Host "`nUseful Commands:"
Write-Host "  View logs:           kubectl logs -l app=hello-flask --tail=50"
Write-Host "  Follow logs:         kubectl logs -l app=hello-flask -f"
Write-Host "  Describe pod:        kubectl describe pod <pod-name>"
Write-Host "  Restart deployment:  kubectl rollout restart deployment/hello-flask"
Write-Host "  Delete deployment:   kubectl delete -f deployment.yaml"

if ($serviceUrl) {
    Write-Host "`nTest Application:"
    Write-Host "  curl $serviceUrl"
    Write-Host "  curl $serviceUrl/health"
}

Write-Host ""
