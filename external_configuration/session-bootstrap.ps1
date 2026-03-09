<#
.SYNOPSIS
    Session Bootstrap - Zero-JSON workflow for AKS-EE single-machine deployments

.DESCRIPTION
    Fill in the variables in the REQUIRED section once, then run this script to
    pre-load all Azure and AIO context into your PS7 session. All subsequent scripts
    (External-Configurator.ps1, grant_entra_id_roles.ps1) will pick up these values
    automatically -- no JSON file editing required.

    Run this script FIRST at the start of every new PS7 session before running
    any other scripts in this folder.

.NOTES
    Requires PowerShell 7+
    Run from the external_configuration/ directory:
        cd external_configuration
        .\session-bootstrap.ps1
#>

# ============================================================================
# REQUIRED: Fill these in once, then run the script
# ============================================================================

$AZ_SUBSCRIPTION_ID    = ""   # Find yours: az account list -o table
$AZ_TENANT_ID          = ""   # Find yours: az account show --query tenantId -o tsv
$AZ_LOCATION           = ""   # e.g. eastus2, westus, westeurope
$AZ_RESOURCE_GROUP     = ""   # Will be created if it does not exist
$AKS_EDGE_CLUSTER_NAME = ""   # Must be lowercase, no spaces
$CUSTOM_LOCATIONS_OID  = ""   # Run: az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
$AZ_CONTAINER_REGISTRY = ""   # Short name only, e.g. myregistry (NOT myregistry.azurecr.io)
                               # Leave blank to let External-Configurator.ps1 auto-generate one

# Optional: set a working directory to cd into automatically
$WORKDIR = ""                  # e.g. C:\workingdir  (leave blank to skip)

# ============================================================================
# DO NOT EDIT BELOW THIS LINE
# ============================================================================

# Validate required fields
$missingFields = @()
if ([string]::IsNullOrWhiteSpace($AZ_SUBSCRIPTION_ID))    { $missingFields += "AZ_SUBSCRIPTION_ID" }
if ([string]::IsNullOrWhiteSpace($AZ_TENANT_ID))          { $missingFields += "AZ_TENANT_ID" }
if ([string]::IsNullOrWhiteSpace($AZ_LOCATION))           { $missingFields += "AZ_LOCATION" }
if ([string]::IsNullOrWhiteSpace($AZ_RESOURCE_GROUP))     { $missingFields += "AZ_RESOURCE_GROUP" }
if ([string]::IsNullOrWhiteSpace($AKS_EDGE_CLUSTER_NAME)) { $missingFields += "AKS_EDGE_CLUSTER_NAME" }
if ([string]::IsNullOrWhiteSpace($CUSTOM_LOCATIONS_OID))  { $missingFields += "CUSTOM_LOCATIONS_OID" }

if ($missingFields.Count -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] The following required variables are not set:" -ForegroundColor Red
    foreach ($field in $missingFields) {
        Write-Host "        $field" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Edit the REQUIRED section at the top of session-bootstrap.ps1 and run again." -ForegroundColor Yellow
    exit 1
}

# Change to working directory if specified
if (-not [string]::IsNullOrWhiteSpace($WORKDIR)) {
    if (Test-Path $WORKDIR) {
        Set-Location $WORKDIR
        Write-Host "[INFO] Working directory set to: $WORKDIR" -ForegroundColor Cyan
    } else {
        Write-Host "[WARN] WORKDIR not found, skipping: $WORKDIR" -ForegroundColor Yellow
    }
}

# Set global variables (consumed by AksEdgeQuickStartForAio.ps1)
$global:SubscriptionId    = $AZ_SUBSCRIPTION_ID
$global:TenantId          = $AZ_TENANT_ID
$global:Location          = $AZ_LOCATION
$global:ResourceGroupName = $AZ_RESOURCE_GROUP
$global:ClusterName       = $AKS_EDGE_CLUSTER_NAME
$global:CustomLocationOID = $CUSTOM_LOCATIONS_OID

# Set environment variables (consumed by az CLI and our scripts)
$env:AZURE_SUBSCRIPTION_ID    = $AZ_SUBSCRIPTION_ID
$env:AZURE_TENANT_ID          = $AZ_TENANT_ID
$env:AZURE_LOCATION           = $AZ_LOCATION
$env:AZURE_RESOURCE_GROUP     = $AZ_RESOURCE_GROUP
$env:AKSEDGE_CLUSTER_NAME     = $AKS_EDGE_CLUSTER_NAME
$env:CUSTOM_LOCATIONS_OID     = $CUSTOM_LOCATIONS_OID
if (-not [string]::IsNullOrWhiteSpace($AZ_CONTAINER_REGISTRY)) {
    $env:AZURE_CONTAINER_REGISTRY = $AZ_CONTAINER_REGISTRY
}

# Log into Azure
Write-Host ""
Write-Host "Logging into Azure (tenant: $AZ_TENANT_ID)..." -ForegroundColor Cyan
az login --tenant $AZ_TENANT_ID | Out-Null
az account set --subscription $AZ_SUBSCRIPTION_ID

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Session ready." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Subscription : $AZ_SUBSCRIPTION_ID" -ForegroundColor Gray
Write-Host "  Tenant       : $AZ_TENANT_ID" -ForegroundColor Gray
Write-Host "  Location     : $AZ_LOCATION" -ForegroundColor Gray
Write-Host "  Resource Grp : $AZ_RESOURCE_GROUP" -ForegroundColor Gray
Write-Host "  Cluster Name : $AKS_EDGE_CLUSTER_NAME" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($AZ_CONTAINER_REGISTRY)) {
    Write-Host "  ACR Name     : $AZ_CONTAINER_REGISTRY" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run AKS-EE quickstart (if not done yet)" -ForegroundColor Gray
Write-Host "  2. .\grant_entra_id_roles.ps1" -ForegroundColor Gray
Write-Host "  3. .\External-Configurator.ps1" -ForegroundColor Gray
Write-Host ""
