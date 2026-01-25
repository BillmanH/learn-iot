<#
.SYNOPSIS
    Deploy Fabric Real-Time Intelligence endpoint to Azure IoT Operations cluster.

.DESCRIPTION
    This script deploys a Kafka endpoint for Microsoft Fabric Real-Time Intelligence.
    It validates prerequisites, updates the YAML with your bootstrap server, stores
    the connection string in Key Vault, and deploys the endpoint to the cluster.
    
    Can be run with parameters or using fabric_config.json configuration file.

.PARAMETER ConfigFile
    Path to fabric_config.json configuration file (default: "fabric_config.json" in script directory)

.PARAMETER BootstrapServer
    The Fabric Event Stream bootstrap server (e.g., "esehmtcyb1tve3fs2la76yiy.servicebus.windows.net:9093")

.PARAMETER EndpointName
    The name for the endpoint (default: "fabric-endpoint")

.PARAMETER KeyVaultName
    The Key Vault name where the connection string will be stored (default: "iot-opps-keys")

.PARAMETER SecretName
    The Key Vault secret name (default: "fabric-connection-string")

.PARAMETER ClusterName
    The Arc-enabled Kubernetes cluster name (default: "iot-ops-cluster")

.PARAMETER ResourceGroup
    The Azure resource group (default: "IoT-Operations")

.PARAMETER SkipPrereqCheck
    Skip prerequisite validation checks

.EXAMPLE
    # Using config file (recommended)
    .\Deploy-FabricEndpoint.ps1

.EXAMPLE
    # Using parameters
    .\Deploy-FabricEndpoint.ps1 -BootstrapServer "esehmtcyb1tve3fs2la76yiy.servicebus.windows.net:9093"

.EXAMPLE
    # Using custom config file
    .\Deploy-FabricEndpoint.ps1 -ConfigFile "my-fabric-config.json"

.NOTES
    Prerequisites:
    - Azure CLI installed
    - kubectl installed
    - Arc cluster proxy connection or direct kubectl access
    - SecretProviderClass 'aio-akv-sp' must exist in azure-iot-operations namespace
    - Secret sync must be enabled on AIO instance
#>

[CmdletBinding(DefaultParameterSetName = 'FromConfig')]
param(
    [Parameter(ParameterSetName = 'FromConfig', Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(ParameterSetName = 'FromParams', Mandatory = $true, HelpMessage = "Fabric Event Stream bootstrap server (e.g., 'server.servicebus.windows.net:9093')")]
    [string]$BootstrapServer,

    [Parameter(Mandatory = $false)]
    [string]$EndpointName,

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$SecretName,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPrereqCheck
)

$ErrorActionPreference = "Stop"

# ============================================================================
# LOGGING SETUP
# ============================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:ScriptDir "fabric_endpoint_deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:Errors = @()

function Initialize-Logging {
    Start-Transcript -Path $script:LogFile -Append
    
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "Deploy Fabric Real-Time Intelligence Endpoint" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "Log file: $script:LogFile" -ForegroundColor Gray
    Write-Host "Started: $(Get-Date)" -ForegroundColor Gray
    Write-Host ""
}

function Stop-Logging {
    Write-Host ""
    Write-Host "Completed: $(Get-Date)" -ForegroundColor Gray
    Write-Host "Log file: $script:LogFile" -ForegroundColor Gray
    Stop-Transcript
}

# Load configuration from file
function Get-FabricConfig {
    param([string]$ConfigPath)
    
    # Determine config file path
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $PSScriptRoot "fabric_config.json"
    }
    
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "WARNING: Config file not found: $ConfigPath" -ForegroundColor Yellow
        Write-Host "INFO: Copy fabric_config.template.json to fabric_config.json and fill in your values" -ForegroundColor Cyan
        return $null
    }
    
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Write-Host "SUCCESS: Loaded configuration from: $ConfigPath" -ForegroundColor Green
        return $config
    }
    catch {
        Write-Host "ERROR: Failed to parse config file: $_" -ForegroundColor Red
        return $null
    }
}

# Color output functions with logging
function Write-Success {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] [SUCCESS] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] [INFO] $Message" -ForegroundColor Cyan
}

function Write-Warning {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] [WARNING] $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param(
        [string]$Message,
        [switch]$Fatal
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[${timestamp}] [ERROR] $Message" -ForegroundColor Red
    
    $script:Errors += $Message
    
    if ($Fatal) {
        Write-Host ""
        Write-Host "Fatal error encountered. Exiting." -ForegroundColor Red
        Write-Host "Check log file for details: $script:LogFile" -ForegroundColor Yellow
        Stop-Logging
        exit 1
    }
}

function Write-Step {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host ""
    Write-Host "[${timestamp}] ==== $Message ====" -ForegroundColor Magenta
}

# Validate bootstrap server format
function Test-BootstrapServer {
    param([string]$Server)
    
    if ($Server -notmatch '^[a-zA-Z0-9\-\.]+:\d+$') {
        Write-ErrorMsg "Invalid bootstrap server format. Expected: 'server.servicebus.windows.net:9093'"
        return $false
    }
    
    if ($Server -notmatch ':9093$') {
        Write-Warning "Bootstrap server should typically use port 9093 for TLS/SASL. You specified: $Server"
    }
    
    return $true
}

# Check prerequisites
function Test-Prerequisites {
    Write-Step "Checking Prerequisites"
    
    $allGood = $true
    
    # Check Azure CLI
    try {
        $null = az version 2>&1
        Write-Success "Azure CLI is installed"
    }
    catch {
        Write-ErrorMsg "Azure CLI is not installed"
        $allGood = $false
    }
    
    # Check kubectl
    try {
        $null = kubectl version --client 2>&1
        Write-Success "kubectl is installed"
    }
    catch {
        Write-ErrorMsg "kubectl is not installed"
        $allGood = $false
    }
    
    # Check kubectl context
    try {
        $context = kubectl config current-context 2>&1
        if ($context -like "*$ClusterName*") {
            Write-Success "kubectl context is set to $ClusterName"
        }
        else {
            Write-Warning "kubectl context is '$context', expected '$ClusterName'"
            Write-Info "Run: az connectedk8s proxy --name $ClusterName --resource-group $ResourceGroup"
        }
    }
    catch {
        Write-Warning "Could not determine kubectl context"
    }
    
    # Check SecretProviderClass
    try {
        $spc = kubectl get secretproviderclass aio-akv-sp -n azure-iot-operations -o name 2>&1
        if ($spc -like "*aio-akv-sp*") {
            Write-Success "SecretProviderClass 'aio-akv-sp' exists"
        }
        else {
            Write-ErrorMsg "SecretProviderClass 'aio-akv-sp' not found"
            Write-Info "Run: .\linux_build\External-Configurator.ps1"
            $allGood = $false
        }
    }
    catch {
        Write-ErrorMsg "Could not check SecretProviderClass (kubectl access issue)"
        $allGood = $false
    }
    
    # Check OIDC issuer
    try {
        $oidc = az connectedk8s show --name $ClusterName --resource-group $ResourceGroup --query "oidcIssuerProfile.enabled" -o tsv 2>&1
        if ($oidc -eq "true") {
            Write-Success "OIDC issuer is enabled"
        }
        else {
            Write-ErrorMsg "OIDC issuer is not enabled"
            Write-Info "Run: az connectedk8s update -n $ClusterName -g $ResourceGroup --enable-oidc-issuer --enable-workload-identity"
            $allGood = $false
        }
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapServer,
        
        [Parameter(Mandatory = $true)]
        [string]$ConnectionString,
        
        [Parameter(Mandatory = $true)]
        [string]$EndpointName,
        
        [Parameter(Mandatory = $true)]
        [string]$KeyVaultName,
        
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $false)]
        [bool]$SkipPrereqCheck = $false
    )
    
    }
    catch {
        Write-Warning "Could not check OIDC issuer status"
    }
    
    # Check secret sync managed identity
    try {
        $mi = az identity show --name "$ClusterName-secretsync-mi" --resource-group $ResourceGroup --query "name" -o tsv 2>$null
        if ($mi) {
            Write-Success "Secret sync managed identity exists"
        }
        else {
            Write-ErrorMsg "Secret sync managed identity not found"
            Write-Info "Run: .\linux_build\External-Configurator.ps1"
            $allGood = $false
        }
    }
    catch {
        Write-Warning "Could not check secret sync managed identity"
    }
    
    return $allGood
}

# Main deployment function
function Deploy-FabricEndpoint {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host "  Deploy Fabric Real-Time Intelligence Endpoint" -ForegroundColor Cyan
    Write-Host "  to Azure IoT Operations" -ForegroundColor Cyan
    Write-Host "================================================================`n" -ForegroundColor Cyan

    # Validate inputs
    Write-Step "Validating Inputs"
    
    if (-not (Test-BootstrapServer -Server $BootstrapServer)) {
        throw "Invalid bootstrap server format"
    }
    Write-Success "Bootstrap server format is valid"
    
    # Check prerequisites
    if (-not $SkipPrereqCheck) {
        if (-not (Test-Prerequisites)) {
            Write-ErrorMsg "Prerequisites check failed. Use -SkipPrereqCheck to bypass."
            throw "Prerequisites not met"
        }
    }
    else {
        Write-Warning "Skipping prerequisite checks"
    }
    
    # Verify connection string secret exists in Key Vault
    Write-Step "Verifying Key Vault Secret"
    
    try {
        Write-Info "Checking for secret '$SecretName' in Key Vault '$KeyVaultName'..."
        $secretCheck = az keyvault secret show --vault-name $KeyVaultName --name $SecretName --query "name" -o tsv 2>$null
        
        if ($secretCheck -eq $SecretName) {
            Write-Success "Secret '$SecretName' found in Key Vault"
            Write-Info "Note: For SASL authentication, the secret should be in JSON format:"
            Write-Host "  {\"username\":\"`$ConnectionString\",\"password\":\"<YOUR_FABRIC_CONNECTION_STRING>\"}" -ForegroundColor Gray
        }
        else {
            Write-ErrorMsg "Secret '$SecretName' not found in Key Vault '$KeyVaultName'"
            Write-Info "To create the secret with proper format for Fabric SASL authentication:"
            Write-Host "  `$json = @{username='`$ConnectionString';password='<YOUR_FABRIC_CONNECTION_STRING>'} | ConvertTo-Json -Compress" -ForegroundColor Gray
            Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name $SecretName --value `"`$json`"" -ForegroundColor Gray
            Write-Host "" -ForegroundColor Gray
            Write-Host "  Or use a simple string (deprecated method):" -ForegroundColor Gray
            Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name $SecretName --value '<YOUR_CONNECTION_STRING>'" -ForegroundColor Gray
            throw "Required Key Vault secret not found"
        }
    }
    catch {
        Write-ErrorMsg "Failed to verify Key Vault secret: $_"
        throw
    }
    
    # Create temporary YAML file with actual values
    Write-Step "Creating Endpoint Configuration"
    
    $yamlPath = Join-Path $PSScriptRoot "fabric-endpoint.yaml"
    $tempYamlPath = Join-Path $env:TEMP "fabric-endpoint-deploy.yaml"
    
    if (-not (Test-Path $yamlPath)) {
        Write-ErrorMsg "YAML template not found: $yamlPath"
        throw "YAML template not found"
    }
    
    # Read template and replace placeholders
    $yamlContent = Get-Content $yamlPath -Raw
    $yamlContent = $yamlContent -replace 'name: fabric-endpoint', "name: $EndpointName"
    $yamlContent = $yamlContent -replace 'host: "YOUR_BOOTSTRAP_SERVER\.servicebus\.windows\.net:9093"', "host: `"$BootstrapServer`""
    $yamlContent = $yamlContent -replace 'secretRef: fabric-connection-string', "secretRef: $SecretName"
    
    # Remove the commented alternative section
    $yamlContent = $yamlContent -split '---' | Select-Object -First 1
    
    # Save to temp file
    $yamlContent | Out-File -FilePath $tempYamlPath -Encoding utf8 -NoNewline
    Write-Success "Endpoint configuration created"
    
    # Deploy to cluster
    Write-Step "Deploying Endpoint to Cluster"
    
    try {
        Write-Info "Applying endpoint configuration..."
        $applyOutput = kubectl apply -f $tempYamlPath 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "kubectl apply failed: $applyOutput"
            throw "Failed to apply endpoint configuration"
        }
        
        Write-Success "Endpoint configuration applied"
        Write-Info "Waiting for endpoint to be created..."
        Start-Sleep -Seconds 5
        
        # Verify deployment with retry logic
        $maxRetries = 3
        $retryCount = 0
        $verified = $false
        
        while ($retryCount -lt $maxRetries -and -not $verified) {
            try {
                $ErrorActionPreference = "Continue"
                $endpoint = kubectl get dataflowendpoint $EndpointName -n azure-iot-operations -o name 2>&1
                $ErrorActionPreference = "Stop"
                
                if ($LASTEXITCODE -eq 0 -and $endpoint -like "*$EndpointName*") {
                    $verified = $true
                    Write-Success "Endpoint '$EndpointName' is deployed and verified"
                    
                    # Show endpoint details
                    Write-Info "Endpoint details:"
                    kubectl get dataflowendpoint $EndpointName -n azure-iot-operations
                    
                    Write-Host ""
                    Write-Info "To view full endpoint configuration:"
                    Write-Host "  kubectl describe dataflowendpoint $EndpointName -n azure-iot-operations" -ForegroundColor Gray
                }
                else {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Info "Endpoint not ready yet, waiting... (attempt $retryCount/$maxRetries)"
                        Start-Sleep -Seconds 3
                    }
                }
            }
            catch {
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Info "Verification attempt failed, retrying... (attempt $retryCount/$maxRetries)"
                    Start-Sleep -Seconds 3
                }
            }
        }
        
        if (-not $verified) {
            Write-Warning "Could not verify endpoint deployment immediately"
            Write-Info "The endpoint may still be provisioning. Check with:"
            Write-Host "  kubectl get dataflowendpoint $EndpointName -n azure-iot-operations" -ForegroundColor Gray
        }
    }
    catch {
        Write-ErrorMsg "Failed to deploy endpoint: $_"
        throw
    }
    finally {
        # Clean up temp file
        if (Test-Path $tempYamlPath) {
            Remove-Item $tempYamlPath -Force
        }
    }
    
    # Display success message
    Write-Host "`n================================================================" -ForegroundColor Green
    Write-Host "  Deployment Complete!" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green

    Write-Host "`nEndpoint Name:       $EndpointName" -ForegroundColor Cyan
    Write-Host "Bootstrap Server:    $BootstrapServer" -ForegroundColor Cyan
    Write-Host "Key Vault Secret:    $KeyVaultName/$SecretName" -ForegroundColor Cyan
    Write-Host "Secret Reference:    aio-akv-sp/$SecretName" -ForegroundColor Cyan
    
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "1. Create a dataflow to route MQTT messages to this endpoint"
    Write-Host "2. Verify data is flowing to Fabric Real-Time Intelligence"
    Write-Host "3. Check Fabric Event Stream for incoming messages"
    
    Write-Host "`nUseful Commands:" -ForegroundColor Yellow
    Write-Host "  List all endpoints:  kubectl get dataflowendpoint -n azure-iot-operations"
    Write-Host "  Describe endpoint:   kubectl describe dataflowendpoint $EndpointName -n azure-iot-operations"
    Write-Host "  Check logs:          kubectl logs -n azure-iot-operations -l app=aio-dataflow-operator --tail=50"
}

# Main script execution
try {
    # Initialize logging
    Initialize-Logging
    
    # Load configuration
    if ($PSCmdlet.ParameterSetName -eq 'FromConfig') {
        $config = Get-FabricConfig -ConfigPath $ConfigFile
        
        if (-not $config) {
            Write-ErrorMsg "No configuration file found. Either:"
            Write-Host "  1. Copy fabric_config.template.json to fabric_config.json and fill in values" -ForegroundColor Gray
            Write-Host "  2. Use command-line parameters: -BootstrapServer and -ConnectionString" -ForegroundColor Gray
            exit 1
        }
        
        # Extract values from config file
        $BootstrapServer = $config.fabric.bootstrapServer
        $EndpointName = if ($EndpointName) { $EndpointName } else { $config.endpoint.name }
        $KeyVaultName = if ($KeyVaultName) { $KeyVaultName } else { $config.azure.keyVault.name }
        $SecretName = if ($SecretName) { $SecretName } else { $config.azure.keyVault.secretName }
        $ClusterName = if ($ClusterName) { $ClusterName } else { $config.azure.cluster.name }
        $ResourceGroup = if ($ResourceGroup) { $ResourceGroup } else { $config.azure.cluster.resourceGroup }
        $SkipPrereqCheck = if ($SkipPrereqCheck) { $SkipPrereqCheck } else { $config.deployment.skipPrereqCheck }
        
        # Validate required config values
        if (-not $BootstrapServer -or $BootstrapServer -like "*YOUR_*") {
            Write-ErrorMsg "Bootstrap server not configured in fabric_config.json"
            exit 1
        }
    }
    else {
        # Using parameters - apply defaults
        if (-not $EndpointName) { $EndpointName = "fabric-endpoint" }
        if (-not $KeyVaultName) { $KeyVaultName = "iot-opps-keys" }
        if (-not $SecretName) { $SecretName = "fabric-connection-string" }
        if (-not $ClusterName) { $ClusterName = "iot-ops-cluster" }
        if (-not $ResourceGroup) { $ResourceGroup = "IoT-Operations" }
    }
    
    # Run deployment function
    Deploy-FabricEndpoint
    
    # Success - stop logging cleanly
    Stop-Logging
}
catch {
    Write-Host ""
    Write-ErrorMsg "Deployment failed: $_" -Fatal
}
