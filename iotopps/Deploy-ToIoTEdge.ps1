<#
.SYNOPSIS
    Deploy application to remote IoT Operations cluster
.DESCRIPTION
    This script deploys a containerized application to an Azure IoT Operations
    K3s cluster running on a remote edge device. It reads configuration from 
    linux_aio_config.json and handles the entire deployment workflow.
.PARAMETER AppFolder
    Name of the application folder under iotopps (e.g., 'hello-flask')
.PARAMETER ConfigPath
    Path to the configuration JSON file (default: ..\linux_build\linux_aio_config.json)
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
    .\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myusername"
.EXAMPLE
    .\Deploy-ToIoTEdge.ps1 -AppFolder "my-app" -RegistryName "myacr" -RegistryType "acr" -ImageTag "v1.0"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AppFolder,
    
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\..\linux_build\linux_aio_config.json",
    
    [Parameter()]
    [ValidateSet('dockerhub', 'acr')]
    [string]$RegistryType,
    
    [Parameter()]
    [string]$RegistryName,
    
    [Parameter()]
    [string]$ImageTag,
    
    [Parameter()]
    [string]$EdgeDeviceIP,
    
    [Parameter()]
    [string]$EdgeDeviceUser = 'azureuser',
    
    [Parameter()]
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# Initialize script-level variables
$script:proxyProcess = $null

# Cleanup function
function Cleanup-ProxyProcess {
    if ($script:proxyProcess -and -not $script:proxyProcess.HasExited) {
        try {
            Stop-Process -Id $script:proxyProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Host "Proxy process stopped." -ForegroundColor Yellow
        } catch {
            # Ignore cleanup errors
        }
    }
}

# Register cleanup on script exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Cleanup-ProxyProcess } | Out-Null

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
    Write-ColorOutput "[OK] $Message" -Color Green
}

function Write-Error-Custom {
    param([string]$Message)
    Write-ColorOutput "[ERROR] $Message" -Color Red
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-ColorOutput "[WARNING] $Message" -Color Yellow
}

function Load-AppConfig {
    param([string]$ConfigPath)
    
    if (Test-Path $ConfigPath) {
        try {
            $appConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            Write-ColorOutput "[OK] App configuration loaded from: $ConfigPath" -Color Green
            return $appConfig
        } catch {
            Write-Warning-Custom "Failed to parse app config: $_"
            return $null
        }
    } else {
        Write-Warning-Custom "App config not found: $ConfigPath"
        return $null
    }
}

# Validate app folder
$appPath = Join-Path $PSScriptRoot $AppFolder
if (-not (Test-Path $appPath)) {
    Write-Error-Custom "Application folder not found: $appPath"
    Write-Host "Available applications in iotopps:"
    Get-ChildItem $PSScriptRoot -Directory | ForEach-Object { Write-Host "  - $($_.Name)" }
    exit 1
}

# Check for required files
if (-not (Test-Path (Join-Path $appPath "Dockerfile"))) {
    Write-Error-Custom "Dockerfile not found in $appPath"
    exit 1
}

if (-not (Test-Path (Join-Path $appPath "deployment.yaml"))) {
    Write-Error-Custom "deployment.yaml not found in $appPath"
    exit 1
}

# Banner
Write-ColorOutput @"

===============================================================
   IoT Edge Deployment - Remote Deployment Tool
   Application: $AppFolder
===============================================================

"@ -Color Cyan

# Load App configuration (for defaults)
$appConfigPath = Join-Path $appPath "$($AppFolder)_config.json"
$appConfig = Load-AppConfig -ConfigPath $appConfigPath

# Apply defaults from app config if parameters not provided
if (-not $RegistryType -and $appConfig) {
    $RegistryType = $appConfig.registry.type
    Write-ColorOutput "Using registry type from config: $RegistryType" -Color Yellow
}
if (-not $RegistryName -and $appConfig) {
    $RegistryName = $appConfig.registry.name
    Write-ColorOutput "Using registry name from config: $RegistryName" -Color Yellow
}
if (-not $ImageTag -and $appConfig) {
    $ImageTag = $appConfig.image.tag
    Write-ColorOutput "Using image tag from config: $ImageTag" -Color Yellow
}

# Set defaults if still not provided
if (-not $RegistryType) { $RegistryType = 'dockerhub' }
if (-not $ImageTag) { $ImageTag = 'latest' }

# Validate required parameters
if (-not $RegistryName) {
    Write-Error-Custom "Registry name is required. Provide via -RegistryName parameter or set in $appConfigPath"
    exit 1
}

# Step 1: Load Azure Configuration
Write-Step "Loading Azure configuration from $ConfigPath"

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

# Check Docker
$dockerAvailable = $false
try {
    $dockerVersion = docker --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "docker is installed"
        $dockerAvailable = $true
    } else {
        throw "Docker check failed"
    }
} catch {
    Write-Warning-Custom "docker is not installed or not in PATH - will skip image build/push"
    Write-Host "  You can build and push the image manually on a machine with Docker"
    $dockerAvailable = $false
}

# Check kubectl
try {
    $kubectlVersion = kubectl version --client 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "kubectl is installed"
    } else {
        throw "kubectl check failed"
    }
} catch {
    Write-Error-Custom "kubectl is not installed or not in PATH"
    exit 1
}

# Check Azure CLI - try multiple methods
$azFound = $false
try {
    # Try direct command
    $azVersion = az --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $azFound = $true
    }
} catch {
    # Command not found, try to find it
}

if (-not $azFound) {
    # Try to find az in common locations
    $azPaths = @(
        "${env:ProgramFiles}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "${env:LOCALAPPDATA}\Programs\Microsoft\Azure CLI\wbin\az.cmd"
    )
    
    foreach ($path in $azPaths) {
        if (Test-Path $path) {
            # Add to PATH for this session
            $azDir = Split-Path $path
            $env:PATH = "$azDir;$env:PATH"
            
            # Test again
            $azVersion = az --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $azFound = $true
                Write-Warning-Custom "Found Azure CLI at: $path (added to PATH for this session)"
                break
            }
        }
    }
}

if ($azFound) {
    Write-Success "az is installed"
} else {
    Write-Error-Custom "az (Azure CLI) is not installed or not in PATH"
    Write-Host "`nPlease install Azure CLI from: https://aka.ms/installazurecliwindows"
    Write-Host "Or restart PowerShell if you just installed it."
    exit 1
}

# Step 3: Build full image name
$imageName = $AppFolder
if ($RegistryType -eq 'acr') {
    $fullImageName = "${RegistryName}.azurecr.io/${imageName}:${ImageTag}"
} else {
    $fullImageName = "${RegistryName}/${imageName}:${ImageTag}"
}

Write-Host "`nTarget Image: $fullImageName"

# Step 4: Build and Push Docker Image (unless skipped)
if (-not $SkipBuild) {
    if (-not $dockerAvailable) {
        Write-Warning-Custom "Docker is not available. Skipping image build and push."
        Write-Host ""
        Write-Host "To build and push the image manually on a machine with Docker:"
        Write-Host "  1. cd $appPath"
        Write-Host "  2. docker build -t ${imageName}:${ImageTag} ."
        Write-Host "  3. docker tag ${imageName}:${ImageTag} $fullImageName"
        Write-Host "  4. docker login  # For Docker Hub, or 'az acr login --name $RegistryName' for ACR"
        Write-Host "  5. docker push $fullImageName"
        Write-Host ""
        Write-Host "After pushing the image, you can re-run this script with -SkipBuild to continue deployment."
        Write-Host ""
        $continueWithoutDocker = Read-Host "Continue with deployment (assumes image already exists in registry)? (y/N)"
        if ($continueWithoutDocker -ne 'y' -and $continueWithoutDocker -ne 'Y') {
            Write-Host "Deployment cancelled."
            exit 0
        }
    } else {
        Write-Step "Building Docker image"
        
        # Change to app directory for build
        Push-Location $appPath
        try {
            docker build -t "${imageName}:${ImageTag}" .
            Write-Success "Docker image built"
        } catch {
            Write-Error-Custom "Docker build failed: $_"
            exit 1
        } finally {
            Pop-Location
        }

        Write-Step "Tagging image"
        docker tag "${imageName}:${ImageTag}" $fullImageName
        Write-Success "Image tagged as $fullImageName"

        Write-Step "Checking container registry authentication"
        if ($RegistryType -eq 'acr') {
            # Check if already logged into ACR by trying to get token
            Write-Host "Checking ACR login status..."
            $acrLoginCheck = az acr login --name $RegistryName --expose-token 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Already authenticated with Azure Container Registry"
            } else {
                try {
                    az acr login --name $RegistryName
                    Write-Success "Logged into Azure Container Registry"
                } catch {
                    Write-Error-Custom "ACR login failed: $_"
                    exit 1
                }
            }
        } else {
            # Check if already logged into Docker Hub
            Write-Host "Checking Docker Hub login status..."
            $dockerInfoOutput = docker info 2>&1 | Out-String
            
            # Check if we're authenticated (look for username in docker info)
            $isLoggedIn = $false
            if ($dockerInfoOutput -match "Username:\s+(\S+)") {
                $currentUser = $matches[1]
                Write-Success "Already authenticated with Docker Hub as '$currentUser'"
                $isLoggedIn = $true
            }
            
            if (-not $isLoggedIn) {
                try {
                    docker login
                    Write-Success "Logged into Docker Hub"
                } catch {
                    Write-Error-Custom "Docker Hub login failed: $_"
                    exit 1
                }
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
    
    # Check for and clean up any existing proxy processes
    Write-Host "Checking for existing proxy processes..."
    $existingProxies = Get-Process -Name "kubectl" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*proxy*" }
    if ($existingProxies) {
        Write-Warning-Custom "Found existing proxy processes. Stopping them..."
        $existingProxies | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    
    # Also try to stop any az connectedk8s proxy processes
    $azProxies = Get-Process | Where-Object { $_.CommandLine -like "*connectedk8s*proxy*" } -ErrorAction SilentlyContinue
    if ($azProxies) {
        Write-Warning-Custom "Found existing Az proxy processes. Stopping them..."
        $azProxies | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    
    # Get the kubeconfig timestamp before starting proxy
    $kubeconfigPath = "$env:USERPROFILE\.kube\config"
    $beforeTimestamp = if (Test-Path $kubeconfigPath) { (Get-Item $kubeconfigPath).LastWriteTime } else { [DateTime]::MinValue }
    
    # Start the proxy in a new process (non-blocking) with a random port to avoid conflicts
    Write-Host "Starting proxy in background process..."
    
    # Use a random port between 47012-47100 to avoid conflicts
    $proxyPort = Get-Random -Minimum 47012 -Maximum 47100
    
    # Create a temp file to capture output
    $proxyLogFile = "$env:TEMP\arc-proxy-$clusterName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    $proxyProcess = Start-Process -FilePath "powershell" -ArgumentList "-Command", "az connectedk8s proxy -n $clusterName -g $resourceGroup --port $proxyPort 2>&1 | Tee-Object -FilePath '$proxyLogFile'" -PassThru -WindowStyle Hidden
    
    Write-Host "Proxy process started (PID: $($proxyProcess.Id)) on port $proxyPort. Waiting for connection..."
    Write-Host "Proxy log file: $proxyLogFile"
    
    # Wait for proxy to be ready (check for kubeconfig changes or timeout after 60 seconds)
    $maxWaitTime = 60
    $waitInterval = 2
    $elapsed = 0
    $proxyReady = $false
    
    while ($elapsed -lt $maxWaitTime) {
        Start-Sleep -Seconds $waitInterval
        $elapsed += $waitInterval
        
        # Check if process is still running
        if ($proxyProcess.HasExited) {
            $errorOutput = if (Test-Path $proxyLogFile) { Get-Content $proxyLogFile -Raw } else { "No log file found" }
            throw "Proxy process exited unexpectedly with code: $($proxyProcess.ExitCode). Error: $errorOutput"
        }
        
        # Check if kubeconfig was updated
        if (Test-Path $kubeconfigPath) {
            $currentTimestamp = (Get-Item $kubeconfigPath).LastWriteTime
            if ($currentTimestamp -gt $beforeTimestamp) {
                # Kubeconfig was updated, give it a moment to complete
                Start-Sleep -Seconds 2
                
                # Check if kubectl can connect
                try {
                    $null = kubectl cluster-info 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $proxyReady = $true
                        Write-Success "Connected to Arc cluster via proxy"
                        break
                    }
                } catch {
                    # Continue waiting
                }
            }
        }
        
        Write-Host "." -NoNewline
    }
    
    if (-not $proxyReady) {
        # Kill the proxy process
        if (-not $proxyProcess.HasExited) {
            Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
        }
        throw "Proxy did not become ready within $maxWaitTime seconds"
    }
    
    # Store the proxy process so we can clean it up later
    $script:proxyProcess = $proxyProcess
    
} catch {
    Write-Warning-Custom "Could not connect via Arc proxy: $_"
    Write-Host "Trying direct kubectl access..."
    
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

$deploymentPath = Join-Path $appPath "deployment.yaml"
$deploymentContent = Get-Content $deploymentPath -Raw
$deploymentContent = $deploymentContent -replace '<YOUR_REGISTRY>', $RegistryName
$deploymentContent = $deploymentContent -replace ':latest', ":${ImageTag}"

$tempDeploymentPath = Join-Path $appPath "deployment.temp.yaml"
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
    kubectl rollout status deployment/$AppFolder --timeout=5m
    Write-Success "Deployment is ready"
} catch {
    Write-Warning-Custom "Deployment status check timed out or failed"
    Write-Host "You can check status manually with: kubectl get pods -l app=$AppFolder"
}

# Step 10: Get service information
Write-Step "Getting service information"
$serviceName = "$AppFolder-service"
try {
    kubectl get service $serviceName
    
    $nodePort = kubectl get service $serviceName -o jsonpath='{.spec.ports[0].nodePort}'
    
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

===============================================================
              Deployment Completed Successfully
===============================================================

"@ -Color Green

Write-Host "Application Details:"
Write-Host "  Application: $AppFolder"
Write-Host "  Image: $fullImageName"
Write-Host "  Cluster: $clusterName"
Write-Host "  Resource Group: $resourceGroup"
if ($serviceUrl) {
    Write-Host "  Service URL: $serviceUrl"
}
Write-Host ""
Write-Host "Useful Commands:"
Write-Host "  View pods:      kubectl get pods -l app=$AppFolder"
Write-Host "  View logs:      kubectl logs -l app=$AppFolder"
Write-Host "  View service:   kubectl get service $serviceName"
Write-Host "  Describe pod:   kubectl describe pod <pod-name>"
Write-Host ""

if ($serviceUrl) {
    Write-Host "Test your application:"
    Write-Host "  curl $serviceUrl"
    Write-Host "  curl $serviceUrl/health"
    Write-Host ""
}

Write-ColorOutput "Deployment script completed!" -Color Green

# Cleanup: Notify about the proxy process if it's still running
if ($script:proxyProcess -and -not $script:proxyProcess.HasExited) {
    Write-Host ""
    Write-ColorOutput "Note: The Arc proxy is still running in the background (PID: $($script:proxyProcess.Id))" -Color Yellow
    Write-Host "To manage the proxy:"
    Write-Host "  Stop proxy:   Stop-Process -Id $($script:proxyProcess.Id) -Force"
    Write-Host "  Check status: Get-Process -Id $($script:proxyProcess.Id) -ErrorAction SilentlyContinue"
    Write-Host ""
    Write-Host "The proxy will stop automatically when you close this PowerShell session."
}
