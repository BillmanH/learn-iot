#Requires -Version 5.1
<#
.SYNOPSIS
    Opens Arc proxies and MQTT port-forwards for side-by-side broker observation.

.DESCRIPTION
    Launches three background terminal windows:
      1. Arc proxy for the NUC cluster (port 47011)
      2. Arc proxy for the ThinkStation cluster (port 47012)
      3. kubectl port-forward tunneling the NUC MQTT broker to localhost:1885

    After running this script, connect MQTT Explorer to:
      - localhost:1883  -> ThinkStation broker (via existing netsh portproxy)
      - localhost:1885  -> NUC broker (via Arc proxy + port-forward)

.NOTES
    Prerequisites:
      - Run 'az login' before executing this script
      - ThinkStation netsh portproxy must be active (localhost:1883 -> AKS EE broker)
      - az CLI and kubectl must be on PATH
#>

[CmdletBinding()]
param(
    [string]$NucClusterName     = "iot-ops-cluster",
    [string]$NucResourceGroup   = "IoT-Operations",
    [string]$ThinkClusterName   = "iot-ops-cluster",
    [string]$ThinkResourceGroup = "msft-thinkstation-ot-rg",
    [string]$Namespace          = "azure-iot-operations",
    [string]$ListenerService    = "publiclistener",
    [int]$NucProxyPort          = 47011,
    [int]$ThinkProxyPort        = 47012,
    [int]$NucMqttLocalPort      = 1885,
    [int]$ThinkMqttLocalPort    = 1883,
    [int]$ProxyWaitSeconds      = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan"    }
        "WARN"  { "Yellow"  }
        "ERROR" { "Red"     }
        "OK"    { "Green"   }
        "STEP"  { "White"   }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-PortListening {
    param([int]$Port)
    try {
        $conn = New-Object System.Net.Sockets.TcpClient
        $result = $conn.BeginConnect("localhost", $Port, $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne(500)
        $conn.Close()
        return $success
    } catch {
        return $false
    }
}

function Wait-ForPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30,
        [string]$Label = "port $Port"
    )
    Write-Log "Waiting for $Label to become available on port $Port..." "INFO"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortListening -Port $Port) {
            Write-Log "$Label is ready on port $Port." "OK"
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Log "Timed out waiting for $Label on port $Port after ${TimeoutSeconds}s." "WARN"
    return $false
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "   AIO Observer Setup - Dual Broker View   " -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

Write-Log "Running pre-flight checks..." "STEP"

# Check required tools
foreach ($tool in @("az", "kubectl")) {
    if (-not (Test-CommandExists $tool)) {
        Write-Log "'$tool' was not found on PATH. Please install it and retry." "ERROR"
        exit 1
    }
    Write-Log "'$tool' found." "OK"
}

# Check az login status
Write-Log "Checking Azure login status..." "INFO"
try {
    $account = az account show --query "{name:name, user:user.name}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Not logged in to Azure. Run 'az login --tenant 1c1264ca-77ff-400d-9608-c7305f777319' first." "ERROR"
        exit 1
    }
    $accountObj = $account | ConvertFrom-Json
    Write-Log "Logged in as: $($accountObj.user) (subscription: $($accountObj.name))" "OK"
} catch {
    Write-Log "Failed to verify Azure login: $_" "ERROR"
    exit 1
}

# Check proxy ports are free
foreach ($port in @($NucProxyPort, $ThinkProxyPort)) {
    if (Test-PortListening -Port $port) {
        Write-Log "Port $port is already in use. A proxy may already be running, or choose a different port." "WARN"
    }
}

# Check if localhost:1883 (ThinkStation) is already forwarded via netsh
Write-Log "Checking ThinkStation MQTT broker availability on localhost:$ThinkMqttLocalPort..." "INFO"
if (Test-PortListening -Port $ThinkMqttLocalPort) {
    Write-Log "localhost:$ThinkMqttLocalPort is already listening (netsh portproxy active)." "OK"
} else {
    Write-Log "localhost:$ThinkMqttLocalPort is NOT listening. The netsh portproxy may be missing." "WARN"
    Write-Log "Run Step 14 from internal_networking_troubleshooting.md to set it up:" "WARN"
    Write-Log '  $lbIP = kubectl get service publiclistener -n azure-iot-operations -o jsonpath=''{.status.loadBalancer.ingress[0].ip}''' "WARN"
    Write-Log "  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=1883 connectaddress=`$lbIP connectport=1883" "WARN"
    Write-Log "Continuing anyway - ThinkStation MQTT Explorer connection may fail." "WARN"
}

Write-Host ""

# ---------------------------------------------------------------------------
# Step 1: Arc proxy for NUC
# ---------------------------------------------------------------------------

Write-Log "[1/3] Launching Arc proxy for NUC cluster '$NucClusterName' on port $NucProxyPort..." "STEP"

$nucProxyCmd = "Write-Host 'ARC PROXY: NUC ($NucClusterName)' -ForegroundColor Cyan; " +
               "Write-Host 'Ctrl+C to stop this proxy window.' -ForegroundColor DarkGray; " +
               "az connectedk8s proxy --name $NucClusterName --resource-group $NucResourceGroup --port $NucProxyPort; " +
               "Write-Host 'Arc proxy exited.' -ForegroundColor Yellow; " +
               "Read-Host 'Press Enter to close'"

try {
    Start-Process pwsh `
        -ArgumentList "-NoExit", "-NoProfile", "-Command", $nucProxyCmd `
        -WindowStyle Normal
    Write-Log "NUC Arc proxy window launched." "OK"
} catch {
    Write-Log "Failed to launch NUC Arc proxy window: $_" "ERROR"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: Arc proxy for ThinkStation
# ---------------------------------------------------------------------------

Write-Log "[2/3] Launching Arc proxy for ThinkStation cluster '$ThinkClusterName' on port $ThinkProxyPort..." "STEP"

$thinkProxyCmd = "Write-Host 'ARC PROXY: THINKSTATION ($ThinkClusterName)' -ForegroundColor Green; " +
                 "Write-Host 'Ctrl+C to stop this proxy window.' -ForegroundColor DarkGray; " +
                 "az connectedk8s proxy --name $ThinkClusterName --resource-group $ThinkResourceGroup --port $ThinkProxyPort; " +
                 "Write-Host 'Arc proxy exited.' -ForegroundColor Yellow; " +
                 "Read-Host 'Press Enter to close'"

try {
    Start-Process pwsh `
        -ArgumentList "-NoExit", "-NoProfile", "-Command", $thinkProxyCmd `
        -WindowStyle Normal
    Write-Log "ThinkStation Arc proxy window launched." "OK"
} catch {
    Write-Log "Failed to launch ThinkStation Arc proxy window: $_" "ERROR"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 3: Wait for NUC proxy, then port-forward MQTT
# ---------------------------------------------------------------------------

Write-Log "[3/3] Waiting up to ${ProxyWaitSeconds}s for NUC Arc proxy to become ready on port $NucProxyPort..." "STEP"

$proxyReady = Wait-ForPort -Port $NucProxyPort -TimeoutSeconds $ProxyWaitSeconds -Label "NUC Arc proxy"

if (-not $proxyReady) {
    Write-Log "NUC Arc proxy did not become ready in time. The port-forward window may fail." "WARN"
    Write-Log "If it fails, manually run in the port-forward window:" "WARN"
    Write-Log "  `$env:HTTPS_PROXY = 'http://localhost:$NucProxyPort'" "WARN"
    Write-Log "  kubectl port-forward svc/$ListenerService ${NucMqttLocalPort}:1883 -n $Namespace" "WARN"
}

Write-Log "Launching NUC MQTT port-forward to localhost:$NucMqttLocalPort..." "STEP"

$portFwdCmd = "Write-Host 'PORT-FORWARD: NUC broker -> localhost:$NucMqttLocalPort' -ForegroundColor Cyan; " +
              "Write-Host 'Requires the NUC Arc proxy window to stay open.' -ForegroundColor DarkGray; " +
              "`$env:HTTPS_PROXY = 'http://localhost:$NucProxyPort'; " +
              "Write-Host 'Connecting via Arc proxy at localhost:$NucProxyPort...' -ForegroundColor DarkGray; " +
              "kubectl port-forward svc/$ListenerService ${NucMqttLocalPort}:1883 -n $Namespace; " +
              "Write-Host 'Port-forward exited.' -ForegroundColor Yellow; " +
              "Read-Host 'Press Enter to close'"

try {
    Start-Process pwsh `
        -ArgumentList "-NoExit", "-NoProfile", "-Command", $portFwdCmd `
        -WindowStyle Normal
    Write-Log "NUC MQTT port-forward window launched." "OK"
} catch {
    Write-Log "Failed to launch NUC MQTT port-forward window: $_" "ERROR"
    exit 1
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "   Observer Setup Complete                 " -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  3 windows have been opened:" -ForegroundColor White
Write-Host "    [Cyan]  Arc proxy  - NUC          (port $NucProxyPort)" -ForegroundColor DarkGray
Write-Host "    [Green] Arc proxy  - ThinkStation  (port $ThinkProxyPort)" -ForegroundColor DarkGray
Write-Host "    [Cyan]  Port-fwd   - NUC MQTT      (-> localhost:$NucMqttLocalPort)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Connect MQTT Explorer to:" -ForegroundColor White
Write-Host "    ThinkStation broker:  localhost:$ThinkMqttLocalPort  (no auth)" -ForegroundColor Green
Write-Host "      Subscribe: nuc/factory/#   <- relayed NUC messages" -ForegroundColor DarkGray
Write-Host "    NUC broker:           localhost:$NucMqttLocalPort  (no auth)" -ForegroundColor Cyan
Write-Host "      Subscribe: factory/#       <- raw simulator output" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To stop: close all 3 proxy/forward windows." -ForegroundColor Yellow
Write-Host ""
