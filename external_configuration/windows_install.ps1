<#
.SYNOPSIS
    Azure IoT Operations - Windows Edge Device Installer

.DESCRIPTION
    This script prepares a Windows machine for Azure IoT Operations development:
    - Enables required Windows features (WSL2, Hyper-V, Containers)
    - Installs K3s via WSL2 or K3d (Docker Desktop)
    - Installs kubectl, Helm, and Azure CLI
    - Configures optional development tools (k9s, mqtt-viewer)
    - Generates cluster_info.json for External-Configurator.ps1
    
    Requirements:
    - Windows 10 (Build 19041+) or Windows 11
    - Administrator privileges
    - Internet connectivity
    - 16GB+ RAM recommended
    
.PARAMETER DryRun
    Validate configuration without making changes
    
.PARAMETER ConfigFile
    Path to configuration file (default: windows_aio_config.json)
    
.PARAMETER SkipVerification
    Skip post-installation verification
    
.PARAMETER ForceReinstall
    Force reinstall of all components

.PARAMETER UseK3d
    Use K3d (K3s in Docker) instead of WSL2 K3s (requires Docker Desktop)
    
.EXAMPLE
    .\windows_install.ps1
    
.EXAMPLE
    .\windows_install.ps1 -DryRun
    
.EXAMPLE
    .\windows_install.ps1 -UseK3d
    
.NOTES
    Author: Azure IoT Operations Team
    Date: January 2026
    Version: 1.0.0 - Windows Edge Installer
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipVerification,
    
    [Parameter(Mandatory=$false)]
    [switch]$ForceReinstall,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseK3d
)

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:ScriptDir "windows_installer_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:EdgeConfigsDir = Join-Path $script:ScriptDir "edge_configs"
$script:ClusterInfoFile = Join-Path $script:EdgeConfigsDir "cluster_info.json"

# Configuration variables
$script:Config = $null
$script:ClusterName = "windows-aio-cluster"
$script:SkipSystemUpdate = $false
$script:K9sEnabled = $false
$script:MqttViewerEnabled = $false
$script:InstalledTools = @()
$script:RequiresReboot = $false

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Initialize-Logging {
    # Create edge_configs directory if it doesn't exist
    if (-not (Test-Path $script:EdgeConfigsDir)) {
        New-Item -ItemType Directory -Path $script:EdgeConfigsDir -Force | Out-Null
    }
    
    Start-Transcript -Path $script:LogFile -Append
    
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host "Azure IoT Operations - Windows Edge Device Installer" -ForegroundColor Cyan
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host "Log file: $script:LogFile" -ForegroundColor Gray
    Write-Host "Started: $(Get-Date)" -ForegroundColor Gray
    Write-Host "Script directory: $script:ScriptDir" -ForegroundColor Gray
    Write-Host ""
    
    if ($DryRun) {
        Write-Warning "RUNNING IN DRY-RUN MODE - No changes will be made"
        Write-Host ""
    }
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] $Message" -ForegroundColor Green
}

function Write-InfoLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] INFO: $Message" -ForegroundColor Cyan
}

function Write-WarnLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Warning "[${timestamp}] WARNING: $Message"
}

function Write-ErrorLog {
    param(
        [string]$Message,
        [switch]$Fatal
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] ERROR: $Message" -ForegroundColor Red
    
    if ($Fatal) {
        Write-Host ""
        Write-Host "Fatal error encountered. Exiting." -ForegroundColor Red
        Write-Host "Check log file for details: $script:LogFile" -ForegroundColor Yellow
        Stop-Transcript
        exit 1
    }
}

function Write-Success {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] SUCCESS: $Message" -ForegroundColor Green
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

function Test-AdminPrivileges {
    Write-Log "Checking administrator privileges..."
    
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-ErrorLog "This script requires administrator privileges"
        Write-Host ""
        Write-Host "Please run PowerShell as Administrator:" -ForegroundColor Yellow
        Write-Host "  1. Right-click on PowerShell" -ForegroundColor Gray
        Write-Host "  2. Select 'Run as Administrator'" -ForegroundColor Gray
        Write-Host "  3. Navigate to this folder and run the script again" -ForegroundColor Gray
        Write-ErrorLog "Administrator privileges required" -Fatal
    }
    
    Write-Success "Administrator privileges verified"
}

function Test-SystemRequirements {
    Write-Log "Checking system requirements..."
    
    # Check Windows version
    $osVersion = [System.Environment]::OSVersion.Version
    $buildNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    
    Write-InfoLog "Windows version: $($osVersion.Major).$($osVersion.Minor) (Build $buildNumber)"
    
    if ([int]$buildNumber -lt 19041) {
        Write-ErrorLog "Windows 10 Build 19041+ or Windows 11 required for WSL2"
        Write-ErrorLog "Current build: $buildNumber" -Fatal
    }
    
    Write-Success "Windows version: Build $buildNumber"
    
    # Check CPU cores
    $cpuCores = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors
    if ($cpuCores -lt 4) {
        Write-WarnLog "CPU cores: $cpuCores (4+ recommended for production)"
    } else {
        Write-Success "CPU cores: $cpuCores"
    }
    
    # Check RAM
    $totalMemGB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($totalMemGB -lt 16) {
        Write-WarnLog "RAM: ${totalMemGB}GB (16GB+ recommended)"
    } else {
        Write-Success "RAM: ${totalMemGB}GB"
    }
    
    # Check disk space
    $systemDrive = $env:SystemDrive
    $diskSpace = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'"
    $freeSpaceGB = [math]::Round($diskSpace.FreeSpace / 1GB)
    
    if ($freeSpaceGB -lt 50) {
        Write-WarnLog "Available disk space on ${systemDrive}: ${freeSpaceGB}GB (50GB+ recommended)"
    } else {
        Write-Success "Disk space on ${systemDrive}: ${freeSpaceGB}GB available"
    }
    
    # Check internet connectivity
    try {
        $null = Test-NetConnection -ComputerName "8.8.8.8" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        Write-Success "Internet connectivity verified"
    } catch {
        Write-ErrorLog "No internet connectivity. Please check your network connection." -Fatal
    }
    
    Write-Log "System requirements check completed"
}

function Test-VirtualizationSupport {
    Write-Log "Checking virtualization support..."
    
    # Check if Hyper-V capable
    $hyperVCapable = (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
    
    if (-not $hyperVCapable) {
        # Check if virtualization is enabled in BIOS
        $virtualization = Get-CimInstance -ClassName Win32_Processor | Select-Object -ExpandProperty VirtualizationFirmwareEnabled
        
        if (-not $virtualization) {
            Write-WarnLog "Hardware virtualization may not be enabled"
            Write-Host "  If WSL2 installation fails, enable virtualization in BIOS:" -ForegroundColor Yellow
            Write-Host "    - Intel: Enable 'Intel VT-x' or 'Intel Virtualization Technology'" -ForegroundColor Gray
            Write-Host "    - AMD: Enable 'AMD-V' or 'SVM Mode'" -ForegroundColor Gray
        }
    } else {
        Write-Success "Hypervisor detected (virtualization enabled)"
    }
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

function Import-LocalConfig {
    Write-Log "Loading configuration..."
    
    # Determine config file path
    $configPath = $null
    
    if ($ConfigFile) {
        if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
            $configPath = $ConfigFile
        } else {
            $configPath = Join-Path $script:ScriptDir $ConfigFile
        }
    } else {
        # Search for config file
        $searchPaths = @(
            (Join-Path $script:ScriptDir "edge_configs\windows_aio_config.json"),
            (Join-Path $script:ScriptDir "windows_aio_config.json"),
            (Join-Path $script:ScriptDir "..\linux_build\edge_configs\linux_aio_config.json"),
            (Join-Path $script:ScriptDir "..\linux_build\linux_aio_config.json")
        )
        
        foreach ($path in $searchPaths) {
            if (Test-Path $path) {
                $configPath = $path
                break
            }
        }
    }
    
    if (-not $configPath -or -not (Test-Path $configPath)) {
        Write-WarnLog "Configuration file not found. Using defaults."
        Write-InfoLog "Create windows_aio_config.json or copy from linux_build/linux_aio_config.template.json"
        
        # Use defaults
        $script:ClusterName = "windows-aio-$(hostname)"
        $script:SkipSystemUpdate = $false
        $script:K9sEnabled = $true
        $script:MqttViewerEnabled = $true
        
        return
    }
    
    Write-InfoLog "Loading configuration from: $configPath"
    
    try {
        $script:Config = Get-Content $configPath -Raw | ConvertFrom-Json
        
        # Load settings
        if ($script:Config.azure.cluster_name) {
            $script:ClusterName = $script:Config.azure.cluster_name
        } else {
            $script:ClusterName = "windows-aio-$(hostname)"
        }
        
        if ($null -ne $script:Config.deployment.skip_system_update) {
            $script:SkipSystemUpdate = $script:Config.deployment.skip_system_update
        }
        
        if ($null -ne $script:Config.optional_tools.k9s) {
            $script:K9sEnabled = $script:Config.optional_tools.k9s
        }
        
        if ($null -ne $script:Config.optional_tools.'mqtt-viewer') {
            $script:MqttViewerEnabled = $script:Config.optional_tools.'mqtt-viewer'
        }
        
        Write-Host ""
        Write-Host "Configuration loaded:" -ForegroundColor Cyan
        Write-Host "  Cluster name: $script:ClusterName" -ForegroundColor Gray
        Write-Host "  Skip system update: $script:SkipSystemUpdate" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Optional tools:" -ForegroundColor Cyan
        Write-Host "  k9s: $script:K9sEnabled" -ForegroundColor Gray
        Write-Host "  mqtt-viewer: $script:MqttViewerEnabled" -ForegroundColor Gray
        Write-Host ""
        
        Write-Success "Configuration loaded successfully"
        
    } catch {
        Write-WarnLog "Failed to parse configuration file: $_"
        Write-InfoLog "Using default configuration"
    }
}

# ============================================================================
# WINDOWS FEATURES
# ============================================================================

function Enable-RequiredWindowsFeatures {
    Write-Log "Enabling required Windows features..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would enable WSL, VirtualMachinePlatform, and Containers features"
        return
    }
    
    $featuresEnabled = $false
    
    # Enable WSL
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
    if ($wslFeature.State -ne "Enabled") {
        Write-Log "Enabling Windows Subsystem for Linux..."
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -WarningAction SilentlyContinue
        $featuresEnabled = $true
        Write-Success "WSL feature enabled"
    } else {
        Write-Success "WSL feature already enabled"
    }
    
    # Enable Virtual Machine Platform (required for WSL2)
    $vmFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    if ($vmFeature.State -ne "Enabled") {
        Write-Log "Enabling Virtual Machine Platform..."
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -WarningAction SilentlyContinue
        $featuresEnabled = $true
        Write-Success "Virtual Machine Platform enabled"
    } else {
        Write-Success "Virtual Machine Platform already enabled"
    }
    
    # Enable Containers (optional, for Docker)
    if ($UseK3d) {
        $containersFeature = Get-WindowsOptionalFeature -Online -FeatureName Containers
        if ($containersFeature.State -ne "Enabled") {
            Write-Log "Enabling Containers feature..."
            Enable-WindowsOptionalFeature -Online -FeatureName Containers -NoRestart -WarningAction SilentlyContinue
            $featuresEnabled = $true
            Write-Success "Containers feature enabled"
        } else {
            Write-Success "Containers feature already enabled"
        }
    }
    
    if ($featuresEnabled) {
        $script:RequiresReboot = $true
        Write-WarnLog "Windows features were enabled. A reboot is required before continuing."
    }
}

function Install-WSL2 {
    Write-Log "Installing/Updating WSL2..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install/update WSL2"
        return
    }
    
    # Check if wsl command exists
    $wslExists = Get-Command wsl -ErrorAction SilentlyContinue
    
    if (-not $wslExists) {
        Write-Log "Installing WSL..."
        wsl --install --no-distribution
        $script:RequiresReboot = $true
        Write-Success "WSL installed (reboot required)"
        return
    }
    
    # Update WSL to latest version
    Write-Log "Updating WSL to latest version..."
    wsl --update 2>&1 | Out-Null
    
    # Set WSL2 as default
    Write-Log "Setting WSL2 as default version..."
    wsl --set-default-version 2 2>&1 | Out-Null
    
    Write-Success "WSL2 is installed and set as default"
}

function Install-UbuntuWSL {
    Write-Log "Installing Ubuntu WSL distribution..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install Ubuntu-24.04 WSL distribution"
        return
    }
    
    # Check if Ubuntu is already installed
    $wslDistros = wsl --list --quiet 2>&1
    if ($wslDistros -match "Ubuntu") {
        Write-Success "Ubuntu WSL distribution already installed"
        
        # Set as default
        $ubuntuDistro = ($wslDistros | Where-Object { $_ -match "Ubuntu" } | Select-Object -First 1).Trim()
        wsl --set-default $ubuntuDistro 2>&1 | Out-Null
        Write-InfoLog "Set '$ubuntuDistro' as default WSL distribution"
        return
    }
    
    # Install Ubuntu 24.04
    Write-Log "Downloading and installing Ubuntu 24.04..."
    wsl --install -d Ubuntu-24.04 --no-launch
    
    Write-Success "Ubuntu 24.04 installed"
    Write-InfoLog "You'll need to set up a username/password on first launch"
    
    $script:RequiresReboot = $true
}

# ============================================================================
# TOOL INSTALLATION
# ============================================================================

function Install-Chocolatey {
    Write-Log "Checking Chocolatey package manager..."
    
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Success "Chocolatey already installed"
        return
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install Chocolatey package manager"
        return
    }
    
    Write-Log "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    
    # Refresh environment
    $env:ChocolateyInstall = "$env:ProgramData\chocolatey"
    $env:PATH = "$env:PATH;$env:ChocolateyInstall\bin"
    
    Write-Success "Chocolatey installed"
}

function Install-Kubectl {
    Write-Log "Installing kubectl..."
    
    if ((Get-Command kubectl -ErrorAction SilentlyContinue) -and -not $ForceReinstall) {
        $version = kubectl version --client --short 2>$null | Select-String -Pattern "v\d+\.\d+\.\d+"
        Write-Success "kubectl already installed: $($version.Matches.Value)"
        return
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install kubectl"
        return
    }
    
    # Install via Chocolatey
    choco install kubernetes-cli -y --no-progress
    
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    
    $script:InstalledTools += "kubectl"
    Write-Success "kubectl installed"
}

function Install-Helm {
    Write-Log "Installing Helm..."
    
    if ((Get-Command helm -ErrorAction SilentlyContinue) -and -not $ForceReinstall) {
        $version = helm version --short 2>$null | Select-String -Pattern "v\d+\.\d+\.\d+"
        Write-Success "Helm already installed: $($version.Matches.Value)"
        return
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install Helm"
        return
    }
    
    # Install via Chocolatey
    choco install kubernetes-helm -y --no-progress
    
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    
    $script:InstalledTools += "helm"
    Write-Success "Helm installed"
}

function Install-AzureCLI {
    Write-Log "Installing Azure CLI..."
    
    if ((Get-Command az -ErrorAction SilentlyContinue) -and -not $ForceReinstall) {
        $version = (az version --output json | ConvertFrom-Json).'azure-cli'
        Write-Success "Azure CLI already installed: $version"
        return
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install Azure CLI"
        return
    }
    
    # Install via Chocolatey
    choco install azure-cli -y --no-progress
    
    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    
    $script:InstalledTools += "az"
    Write-Success "Azure CLI installed"
}

function Install-K9s {
    if (-not $script:K9sEnabled) {
        return
    }
    
    Write-Log "Installing k9s (Kubernetes terminal UI)..."
    
    if ((Get-Command k9s -ErrorAction SilentlyContinue) -and -not $ForceReinstall) {
        Write-Success "k9s already installed"
        return
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install k9s"
        return
    }
    
    # Install via Chocolatey
    choco install k9s -y --no-progress
    
    $script:InstalledTools += "k9s"
    Write-Success "k9s installed"
}

function Install-MqttTools {
    if (-not $script:MqttViewerEnabled) {
        return
    }
    
    Write-Log "Installing MQTT tools (mosquitto)..."
    
    if ((Get-Command mosquitto_sub -ErrorAction SilentlyContinue) -and -not $ForceReinstall) {
        Write-Success "Mosquitto clients already installed"
        return
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install mosquitto"
        return
    }
    
    # Install via Chocolatey
    choco install mosquitto -y --no-progress
    
    $script:InstalledTools += "mosquitto-clients"
    Write-Success "MQTT tools installed (mosquitto_sub, mosquitto_pub)"
}

function Install-OptionalTools {
    Write-Log "Installing optional tools based on configuration..."
    
    Install-K9s
    Install-MqttTools
    
    if ($script:InstalledTools.Count -eq 0) {
        Write-InfoLog "No optional tools were installed"
    }
}

# ============================================================================
# K3S INSTALLATION (WSL2 or K3d)
# ============================================================================

function Install-K3sInWSL {
    Write-Log "Installing K3s in WSL2 Ubuntu..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install K3s in WSL2"
        return
    }
    
    # Check if WSL is ready
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "WSL is not ready. Please complete WSL setup first."
        Write-Host "  Run 'wsl --install' and reboot if needed" -ForegroundColor Yellow
        Write-ErrorLog "WSL not ready" -Fatal
    }
    
    # Check if Ubuntu is installed and running
    $ubuntuReady = wsl -d Ubuntu-24.04 -- echo "ready" 2>&1
    if ($ubuntuReady -ne "ready") {
        Write-WarnLog "Ubuntu WSL is not ready. Please complete initial setup."
        Write-Host ""
        Write-Host "To complete Ubuntu setup:" -ForegroundColor Yellow
        Write-Host "  1. Run: wsl -d Ubuntu-24.04" -ForegroundColor Gray
        Write-Host "  2. Create a username and password when prompted" -ForegroundColor Gray
        Write-Host "  3. Exit and re-run this script" -ForegroundColor Gray
        Write-Host ""
        Write-ErrorLog "Ubuntu WSL needs initial setup" -Fatal
    }
    
    # Install K3s inside WSL
    Write-Log "Running K3s installation inside WSL..."
    
    $k3sInstallScript = @'
#!/bin/bash
set -e

# Check if K3s is already running
if sudo systemctl is-active --quiet k3s 2>/dev/null; then
    echo "K3s is already installed and running"
    exit 0
fi

# Install K3s
curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --disable traefik

# Wait for K3s to be ready
echo "Waiting for K3s to be ready..."
for i in {1..30}; do
    if sudo k3s kubectl get nodes &>/dev/null; then
        echo "K3s is ready!"
        break
    fi
    sleep 5
done

# Copy kubeconfig to user directory
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config

echo "K3s installation complete"
'@
    
    # Write script to temp file and execute in WSL
    $tempScript = Join-Path $env:TEMP "install_k3s.sh"
    $k3sInstallScript | Out-File -FilePath $tempScript -Encoding utf8 -Force
    
    # Convert Windows path to WSL path
    $wslTempScript = wsl wslpath -u ($tempScript -replace '\\', '/')
    
    # Execute in WSL
    wsl -d Ubuntu-24.04 -- bash $wslTempScript
    
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "K3s installation in WSL failed" -Fatal
    }
    
    Write-Success "K3s installed in WSL2"
    
    # Configure Windows kubectl to use WSL kubeconfig
    Configure-KubectlForWSL
}

function Configure-KubectlForWSL {
    Write-Log "Configuring kubectl to connect to WSL K3s cluster..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would configure kubectl for WSL K3s"
        return
    }
    
    # Get kubeconfig from WSL
    $wslKubeconfig = wsl -d Ubuntu-24.04 -- cat ~/.kube/config 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "Failed to get kubeconfig from WSL"
        Write-ErrorLog $wslKubeconfig -Fatal
    }
    
    # Get WSL IP address
    $wslIP = wsl -d Ubuntu-24.04 -- hostname -I 2>&1 | ForEach-Object { $_.Trim().Split()[0] }
    
    Write-InfoLog "WSL IP address: $wslIP"
    
    # Replace localhost with WSL IP in kubeconfig
    $wslKubeconfig = $wslKubeconfig -replace 'https://127.0.0.1:', "https://${wslIP}:"
    
    # Create Windows .kube directory
    $kubeDir = "$env:USERPROFILE\.kube"
    if (-not (Test-Path $kubeDir)) {
        New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null
    }
    
    # Save kubeconfig
    $kubeconfigPath = "$kubeDir\config"
    $wslKubeconfig | Out-File -FilePath $kubeconfigPath -Encoding utf8 -Force
    
    Write-Success "kubectl configured to use WSL K3s cluster"
    
    # Test connection
    Write-Log "Testing kubectl connection..."
    $nodes = kubectl get nodes --no-headers 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Successfully connected to K3s cluster"
        kubectl get nodes
    } else {
        Write-WarnLog "Could not connect to K3s cluster from Windows"
        Write-InfoLog "You may need to use kubectl from within WSL"
    }
}

function Install-K3d {
    Write-Log "Installing K3d (K3s in Docker)..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install K3d and create cluster"
        return
    }
    
    # Check if Docker is installed and running
    $dockerRunning = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "Docker is not running or not installed"
        Write-Host ""
        Write-Host "To use K3d, install Docker Desktop:" -ForegroundColor Yellow
        Write-Host "  1. Download from: https://www.docker.com/products/docker-desktop" -ForegroundColor Gray
        Write-Host "  2. Install and start Docker Desktop" -ForegroundColor Gray
        Write-Host "  3. Re-run this script" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Or use WSL2 instead:" -ForegroundColor Yellow
        Write-Host "  .\windows_install.ps1 (without -UseK3d)" -ForegroundColor Gray
        Write-ErrorLog "Docker not available" -Fatal
    }
    
    # Install K3d via Chocolatey
    if (-not (Get-Command k3d -ErrorAction SilentlyContinue) -or $ForceReinstall) {
        Write-Log "Installing K3d..."
        choco install k3d -y --no-progress
        
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    } else {
        Write-Success "K3d already installed"
    }
    
    # Check if cluster already exists
    $existingCluster = k3d cluster list --no-headers 2>&1 | Select-String $script:ClusterName
    
    if ($existingCluster) {
        Write-Success "K3d cluster '$($script:ClusterName)' already exists"
        
        # Ensure kubeconfig is set
        k3d kubeconfig merge $script:ClusterName --kubeconfig-switch-context
        return
    }
    
    # Create K3d cluster
    Write-Log "Creating K3d cluster: $($script:ClusterName)..."
    k3d cluster create $script:ClusterName `
        --api-port 6443 `
        --servers 1 `
        --agents 0 `
        --k3s-arg "--disable=traefik@server:0" `
        --wait
    
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "Failed to create K3d cluster" -Fatal
    }
    
    # Merge kubeconfig
    k3d kubeconfig merge $script:ClusterName --kubeconfig-switch-context
    
    Write-Success "K3d cluster created: $($script:ClusterName)"
    
    # Test connection
    kubectl get nodes
}

function Install-CSISecretStore {
    Write-Log "Installing CSI Secret Store driver for Azure Key Vault integration..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would install CSI Secret Store driver"
        return
    }
    
    # Check if already installed
    $csiDriver = kubectl get csidriver secrets-store.csi.k8s.io --ignore-not-found 2>&1
    
    if ($csiDriver -and $LASTEXITCODE -eq 0 -and -not $ForceReinstall) {
        Write-Success "CSI Secret Store driver already installed"
        return
    }
    
    # Add Helm repos
    Write-Log "Adding Secrets Store CSI Driver Helm repository..."
    helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
    helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
    helm repo update
    
    # Install CSI driver
    Write-Log "Installing Secrets Store CSI Driver..."
    helm upgrade --install csi-secrets-store-driver secrets-store-csi-driver/secrets-store-csi-driver `
        --namespace kube-system `
        --set syncSecret.enabled=true `
        --set enableSecretRotation=true `
        --wait
    
    # Install Azure provider
    Write-Log "Installing Azure Key Vault Provider..."
    helm upgrade --install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure `
        --namespace kube-system `
        --wait
    
    Write-Success "CSI Secret Store driver and Azure provider installed"
}

# ============================================================================
# CLUSTER INFO GENERATION
# ============================================================================

function Export-ClusterInfo {
    Write-Log "Generating cluster information file..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would generate cluster_info.json"
        return
    }
    
    # Ensure edge_configs directory exists
    if (-not (Test-Path $script:EdgeConfigsDir)) {
        New-Item -ItemType Directory -Path $script:EdgeConfigsDir -Force | Out-Null
    }
    
    # Get cluster information
    $nodeName = kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>$null
    $k8sVersion = kubectl version --output=json 2>$null | ConvertFrom-Json
    $nodeOS = kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>$null
    
    # Get kubeconfig and encode
    $kubeconfigPath = "$env:USERPROFILE\.kube\config"
    $kubeconfigContent = Get-Content $kubeconfigPath -Raw
    $kubeconfigBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($kubeconfigContent))
    
    # Build cluster info object
    $clusterInfo = @{
        cluster_name = $script:ClusterName
        node_name = $nodeName
        kubernetes_version = $k8sVersion.serverVersion.gitVersion
        node_os = $nodeOS
        platform = "windows"
        installation_method = if ($UseK3d) { "k3d" } else { "wsl2-k3s" }
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        ready_for_arc = $true
        kubeconfig_base64 = $kubeconfigBase64
        installed_tools = $script:InstalledTools
    }
    
    # Save to file
    $clusterInfo | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ClusterInfoFile
    
    Write-Success "Cluster info saved to: $($script:ClusterInfoFile)"
}

# ============================================================================
# VERIFICATION
# ============================================================================

function Test-Installation {
    if ($SkipVerification) {
        Write-InfoLog "Skipping verification (-SkipVerification flag)"
        return
    }
    
    Write-Log "Verifying installation..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify installation"
        return
    }
    
    $allPassed = $true
    
    # Check kubectl
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        Write-Success "kubectl: installed"
    } else {
        Write-WarnLog "kubectl: not found"
        $allPassed = $false
    }
    
    # Check helm
    if (Get-Command helm -ErrorAction SilentlyContinue) {
        Write-Success "helm: installed"
    } else {
        Write-WarnLog "helm: not found"
        $allPassed = $false
    }
    
    # Check Azure CLI
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Success "Azure CLI: installed"
    } else {
        Write-WarnLog "Azure CLI: not found"
        $allPassed = $false
    }
    
    # Check cluster connectivity
    $nodes = kubectl get nodes --no-headers 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Cluster connectivity: OK"
        kubectl get nodes
    } else {
        Write-WarnLog "Cluster connectivity: Failed"
        Write-WarnLog $nodes
        $allPassed = $false
    }
    
    # Check CSI driver
    $csiDriver = kubectl get csidriver secrets-store.csi.k8s.io --ignore-not-found 2>&1
    if ($csiDriver -and $LASTEXITCODE -eq 0) {
        Write-Success "CSI Secret Store: installed"
    } else {
        Write-WarnLog "CSI Secret Store: not installed"
    }
    
    if ($allPassed) {
        Write-Success "All verification checks passed"
    } else {
        Write-WarnLog "Some verification checks failed - review warnings above"
    }
}

# ============================================================================
# COMPLETION SUMMARY
# ============================================================================

function Show-CompletionSummary {
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host "Windows Edge Device Installation Complete!" -ForegroundColor Cyan
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host ""
    
    if ($script:RequiresReboot) {
        Write-Host "!!! REBOOT REQUIRED !!!" -ForegroundColor Red
        Write-Host ""
        Write-Host "Windows features were enabled that require a reboot." -ForegroundColor Yellow
        Write-Host "After rebooting, run this script again to complete installation." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To reboot now: Restart-Computer" -ForegroundColor Gray
        Write-Host ""
        return
    }
    
    Write-Host "Cluster Information:" -ForegroundColor Green
    Write-Host "  Cluster Name: $script:ClusterName" -ForegroundColor Gray
    Write-Host "  Installation Method: $(if ($UseK3d) { 'K3d (Docker)' } else { 'WSL2 K3s' })" -ForegroundColor Gray
    Write-Host "  Cluster Info File: $script:ClusterInfoFile" -ForegroundColor Gray
    Write-Host ""
    
    if ($script:InstalledTools.Count -gt 0) {
        Write-Host "Installed Tools:" -ForegroundColor Green
        foreach ($tool in $script:InstalledTools) {
            Write-Host "  - $tool" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Copy cluster_info.json to your management machine" -ForegroundColor Gray
    Write-Host "  2. Run External-Configurator.ps1 to Arc-enable and deploy AIO" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Commands to try:" -ForegroundColor Cyan
    Write-Host "  kubectl get nodes              # View cluster nodes" -ForegroundColor Gray
    Write-Host "  kubectl get pods -A            # View all pods" -ForegroundColor Gray
    if ($script:K9sEnabled) {
        Write-Host "  k9s                            # Interactive cluster UI" -ForegroundColor Gray
    }
    Write-Host ""
    
    if (-not $UseK3d) {
        Write-Host "WSL Tips:" -ForegroundColor Cyan
        Write-Host "  wsl -d Ubuntu-24.04            # Enter WSL shell" -ForegroundColor Gray
        Write-Host "  wsl --shutdown                 # Stop WSL (stops K3s too)" -ForegroundColor Gray
        Write-Host ""
    }
    
    Write-Host "============================================================================" -ForegroundColor Cyan
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Main {
    try {
        Initialize-Logging
        
        Write-Log "Starting Windows Edge Device Installer"
        Write-Log "Version: 1.0.0"
        
        # Pre-flight checks
        Test-AdminPrivileges
        Test-SystemRequirements
        Test-VirtualizationSupport
        
        # Load configuration
        Import-LocalConfig
        
        # Enable Windows features
        Enable-RequiredWindowsFeatures
        
        if ($script:RequiresReboot) {
            Show-CompletionSummary
            Stop-Transcript
            exit 0
        }
        
        # Install WSL2 (if not using K3d)
        if (-not $UseK3d) {
            Install-WSL2
            Install-UbuntuWSL
            
            if ($script:RequiresReboot) {
                Show-CompletionSummary
                Stop-Transcript
                exit 0
            }
        }
        
        # Install package manager and tools
        Install-Chocolatey
        Install-Kubectl
        Install-Helm
        Install-AzureCLI
        Install-OptionalTools
        
        # Install Kubernetes cluster
        if ($UseK3d) {
            Install-K3d
        } else {
            Install-K3sInWSL
        }
        
        # Install CSI Secret Store
        Install-CSISecretStore
        
        # Generate cluster info
        Export-ClusterInfo
        
        # Verify installation
        Test-Installation
        
        # Show completion summary
        Show-CompletionSummary
        
        Write-Log "Windows Edge Device Installer completed successfully"
        
    } catch {
        Write-ErrorLog "Unexpected error: $_"
        Write-ErrorLog $_.ScriptStackTrace
        Write-ErrorLog "Installation failed" -Fatal
    } finally {
        Stop-Transcript
    }
}

# Run main function
Main
