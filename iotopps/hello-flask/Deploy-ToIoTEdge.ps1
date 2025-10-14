<#
.SYNOPSIS
    Deploy Flask application to remote IoT Operations cluster
.DESCRIPTION
    This script deploys the Flask hello-world container to an Azure IoT Operations
    K3s cluster running on a remote edge device. It reads configuration from 
    linux_aio_config.json and handles the entire deployment workflow.
.PARAMETER ConfigPath
    Path to the configuration JSON file (default: ..\..\..\linux_build\linux_aio_config.json)
.PARAMETER RegistryType
    Container registry type: 'dockerhub' or 'acr' (default: dockerhub)
.PARAMETER RegistryName
    Your Docker Hub username or ACR name (required)
.PARAMETER ImageTag
    Docker image tag (default: latest)
.PARAMETER EdgeDeviceIP
    Optional: Override edge device IP from config
.PARAMETER EdgeDeviceUser
    Username for SSH to edge device (default: azureuser)
.PARAMETER SkipBuild
    Skip building and pushing the Docker image
.EXAMPLE
    .\Deploy-ToIoTEdge.ps1 -RegistryName "myusername"
.EXAMPLE
    .\Deploy-ToIoTEdge.ps1 -RegistryName "myacr" -RegistryType "acr" -ImageTag "v1.0"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\..\..\..\linux_build\linux_aio_config.json",
    
    [Parameter()]
    [ValidateSet('dockerhub', 'acr')]
    [string]$RegistryType = 'dockerhub',
    
    [Parameter(Mandatory=$true)]
    [string]$RegistryName,
    
    [Parameter()]
    [string]$ImageTag = 'latest',
    
    [Parameter()]
    [string]$EdgeDeviceIP,
    
    [Parameter()]
    [string]$EdgeDeviceUser = 'azureuser',
    
    [Parameter()]
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# Color output functions
function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Write-Step {
    param([string]$Message)
    Write-ColorOutput "`n==> $Message" -Color Cyan
}

function Write-Success {
    param([string]$Message)
    Write-ColorOutput "✓ $Message" -Color Green
}

function Write-Error-Custom {
    param([string]$Message)
    Write-ColorOutput "✗ $Message" -Color Red
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-ColorOutput "⚠ $Message" -Color Yellow
}

# Banner
Write-ColorOutput @"

╔═══════════════════════════════════════════════════════════╗
║   Flask IoT Edge Deployment - Remote Deployment Tool     ║
╚═══════════════════════════════════════════════════════════╝

"@ -Color Cyan

# Step 1: Load Configuration
Write-Step "Loading configuration from $ConfigPath"

if (-not (Test-Path $ConfigPath)) {
    Write-Error-Custom "Configuration file not found: $ConfigPath"
    Write-Host "`nPlease ensure linux_aio_config.json exists with your cluster configuration."
    exit 1
}

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Success "Configuration loaded"
    Write-Host "  Resource Group: $($config.azure.resource_group)"
    Write-Host "  Cluster Name: $($config.azure.cluster_name)"
    Write-Host "  Location: $($config.azure.location)"
} catch {
    Write-Error-Custom "Failed to parse configuration file: $_"
    exit 1
}

# Step 2: Validate Prerequisites
Write-Step "Validating prerequisites"

$prerequisites = @(
    @{Name='docker'; Command='docker --version'},
    @{Name='kubectl'; Command='kubectl version --client'},
    @{Name='az'; Command='az --version'}
)

foreach ($prereq in $prerequisites) {
    try {
        $null = Invoke-Expression $prereq.Command 2>&1
        Write-Success "$($prereq.Name) is installed"
    } catch {
        Write-Error-Custom "$($prereq.Name) is not installed or not in PATH"
        exit 1
    }
}

# Step 3: Build full image name
$imageName = "hello-flask"
if ($RegistryType -eq 'acr') {
    $fullImageName = "${RegistryName}.azurecr.io/${imageName}:${ImageTag}"
} else {
    $fullImageName = "${RegistryName}/${imageName}:${ImageTag}"
}

Write-Host "`nTarget Image: $fullImageName"

# Step 4: Build and Push Docker Image (unless skipped)
if (-not $SkipBuild) {
    Write-Step "Building Docker image"
    
    try {
        docker build -t "${imageName}:${ImageTag}" .
        Write-Success "Docker image built"
    } catch {
        Write-Error-Custom "Docker build failed: $_"
        exit 1
    }

    Write-Step "Tagging image"
    docker tag "${imageName}:${ImageTag}" $fullImageName
    Write-Success "Image tagged as $fullImageName"

    Write-Step "Logging into container registry"
    if ($RegistryType -eq 'acr') {
        try {
            az acr login --name $RegistryName
            Write-Success "Logged into Azure Container Registry"
        } catch {
            Write-Error-Custom "ACR login failed: $_"
            exit 1
        }
    } else {
        try {
            docker login
            Write-Success "Logged into Docker Hub"
        } catch {
            Write-Error-Custom "Docker Hub login failed: $_"
            exit 1
        }
    }

    Write-Step "Pushing image to registry"
    try {
        docker push $fullImageName
        Write-Success "Image pushed successfully"
    } catch {
        Write-Error-Custom "Docker push failed: $_"
        exit 1
    }
} else {
    Write-Warning-Custom "Skipping build and push (using existing image: $fullImageName)"
}

# Step 5: Configure kubectl for Arc-enabled cluster
Write-Step "Configuring kubectl for Arc-enabled cluster"

$clusterName = $config.azure.cluster_name
$resourceGroup = $config.azure.resource_group
$subscriptionId = $config.azure.subscription_id

# Set subscription if specified
if ($subscriptionId) {
    try {
        az account set --subscription $subscriptionId
        Write-Success "Using subscription: $subscriptionId"
    } catch {
        Write-Warning-Custom "Could not set subscription. Using current subscription."
    }
}

# Get Arc cluster credentials
try {
    Write-Host "Getting credentials for Arc-enabled cluster..."
    Start-Process -FilePath "az" -ArgumentList "connectedk8s","proxy","-n",$clusterName,"-g",$resourceGroup -NoNewWindow
    Start-Sleep -Seconds 5
    Write-Success "Connected to Arc cluster via proxy"
} catch {
    Write-Warning-Custom "Could not connect via Arc proxy. Trying direct kubectl access..."
    
    # Alternative: Try to get kubeconfig directly if edge device is accessible
    if ($EdgeDeviceIP) {
        Write-Host "Attempting direct connection to edge device at $EdgeDeviceIP"
        
        # Copy kubeconfig from edge device
        $kubeconfigPath = "$env:USERPROFILE\.kube\config-edge"
        try {
            scp "${EdgeDeviceUser}@${EdgeDeviceIP}:/etc/rancher/k3s/k3s.yaml" $kubeconfigPath
            
            # Update server address in kubeconfig
            $kubeconfigContent = Get-Content $kubeconfigPath -Raw
            $kubeconfigContent = $kubeconfigContent -replace '127.0.0.1', $EdgeDeviceIP
            $kubeconfigContent = $kubeconfigContent -replace 'localhost', $EdgeDeviceIP
            Set-Content -Path $kubeconfigPath -Value $kubeconfigContent
            
            $env:KUBECONFIG = $kubeconfigPath
            Write-Success "Retrieved kubeconfig from edge device"
        } catch {
            Write-Error-Custom "Could not retrieve kubeconfig from edge device: $_"
            Write-Host "`nPlease ensure:"
            Write-Host "  1. SSH access is enabled on the edge device"
            Write-Host "  2. You have the correct credentials"
            Write-Host "  3. The edge device IP is correct: $EdgeDeviceIP"
            exit 1
        }
    } else {
        Write-Error-Custom "Could not connect to cluster. Please provide -EdgeDeviceIP parameter."
        exit 1
    }
}

# Step 6: Verify cluster connectivity
Write-Step "Verifying cluster connectivity"
try {
    $nodes = kubectl get nodes --no-headers 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl get nodes failed"
    }
    Write-Success "Connected to cluster"
    Write-Host "Nodes:"
    kubectl get nodes
} catch {
    Write-Error-Custom "Cannot connect to cluster: $_"
    Write-Host "`nTroubleshooting:"
    Write-Host "  1. Verify the cluster is running: az connectedk8s list -g $resourceGroup"
    Write-Host "  2. Check Arc agent status: az connectedk8s show -n $clusterName -g $resourceGroup"
    Write-Host "  3. Ensure you have proper RBAC permissions"
    exit 1
}

# Step 7: Create deployment manifest with registry name
Write-Step "Creating deployment manifest"

$deploymentContent = Get-Content "$PSScriptRoot\deployment.yaml" -Raw
$deploymentContent = $deploymentContent -replace '<YOUR_REGISTRY>', $RegistryName
$deploymentContent = $deploymentContent -replace ':latest', ":${ImageTag}"

$tempDeploymentPath = "$PSScriptRoot\deployment.temp.yaml"
Set-Content -Path $tempDeploymentPath -Value $deploymentContent
Write-Success "Deployment manifest created"

# Step 8: Apply deployment
Write-Step "Deploying to Kubernetes cluster"
try {
    kubectl apply -f $tempDeploymentPath
    Write-Success "Deployment applied"
} catch {
    Write-Error-Custom "Deployment failed: $_"
    Remove-Item $tempDeploymentPath -ErrorAction SilentlyContinue
    exit 1
} finally {
    Remove-Item $tempDeploymentPath -ErrorAction SilentlyContinue
}

# Step 9: Wait for deployment
Write-Step "Waiting for deployment to be ready"
try {
    kubectl rollout status deployment/hello-flask --timeout=5m
    Write-Success "Deployment is ready"
} catch {
    Write-Warning-Custom "Deployment status check timed out or failed"
    Write-Host "You can check status manually with: kubectl get pods -l app=hello-flask"
}

# Step 10: Get service information
Write-Step "Getting service information"
try {
    kubectl get service hello-flask-service
    
    $nodePort = kubectl get service hello-flask-service -o jsonpath='{.spec.ports[0].nodePort}'
    
    if ($EdgeDeviceIP) {
        $serviceUrl = "http://${EdgeDeviceIP}:${nodePort}"
    } else {
        # Try to get node IP from cluster
        $nodeIP = kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
        $serviceUrl = "http://${nodeIP}:${nodePort}"
    }
    
    Write-Success "Service is exposed"
} catch {
    Write-Warning-Custom "Could not retrieve service information"
}

# Step 11: Display summary
Write-ColorOutput @"

╔═══════════════════════════════════════════════════════════╗
║              Deployment Completed Successfully            ║
╚═══════════════════════════════════════════════════════════╝

"@ -Color Green

Write-Host "Application Details:"
Write-Host "  Image: $fullImageName"
Write-Host "  Cluster: $clusterName"
Write-Host "  Resource Group: $resourceGroup"
if ($serviceUrl) {
    Write-Host "  Service URL: $serviceUrl"
}
Write-Host ""
Write-Host "Useful Commands:"
Write-Host "  View pods:      kubectl get pods -l app=hello-flask"
Write-Host "  View logs:      kubectl logs -l app=hello-flask"
Write-Host "  View service:   kubectl get service hello-flask-service"
Write-Host "  Describe pod:   kubectl describe pod <pod-name>"
Write-Host ""

if ($serviceUrl) {
    Write-Host "Test your application:"
    Write-Host "  curl $serviceUrl"
    Write-Host "  curl $serviceUrl/health"
    Write-Host ""
}

Write-ColorOutput "Deployment script completed!" -Color Green
