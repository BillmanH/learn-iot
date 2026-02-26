# ==============================================================================
# resume.ps1
# Starts a previously suspended (deallocated) edge VM.
# After the VM boots, cloud-init does NOT re-run (K3s and all tools persist).
# Arc connectivity should automatically re-establish within a few minutes.
#
# Usage:
#   pwsh scripts/resume.ps1
# ==============================================================================

$ErrorActionPreference = 'Stop'

$azdEnv = (azd env get-values --output json 2>$null | ConvertFrom-Json -AsHashtable)
$resourceGroup = $azdEnv['AZURE_RESOURCE_GROUP']
$vmName        = $azdEnv['AZURE_VM_NAME']
$clusterName   = $azdEnv['AIO_CLUSTER_NAME']

if (-not $vmName) {
    Write-Error "AZURE_VM_NAME not found in azd environment. Run from azd-deploy/ directory."
    exit 1
}

Write-Host "Starting VM: $vmName (resource group: $resourceGroup)"
az vm start --resource-group $resourceGroup --name $vmName

# Show new public IP (may change after deallocation if not using static allocation)
$newIp = az vm show -d --resource-group $resourceGroup --name $vmName --query publicIps -o tsv
Write-Host ""
Write-Host "VM started. Public IP: $newIp"
Write-Host ""
Write-Host "Arc connectivity will re-establish automatically in ~2-5 minutes."
Write-Host "Check Arc status: az connectedk8s show --name $clusterName --resource-group $resourceGroup"
Write-Host ""
Write-Host "To reconnect kubectl:"
Write-Host "  az connectedk8s proxy --name $clusterName --resource-group $resourceGroup"
