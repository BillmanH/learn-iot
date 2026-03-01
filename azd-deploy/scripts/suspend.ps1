# ==============================================================================
# suspend.ps1
# Deallocates the edge VM to stop compute billing while keeping all Azure
# resources intact (Key Vault, Storage, Schema Registry, ACR, Arc registration).
#
# Usage:
#   pwsh scripts/suspend.ps1
#
# Resume with:
#   pwsh scripts/resume.ps1
# ==============================================================================

$ErrorActionPreference = 'Stop'

# PS 5.1-compatible: convert a PSCustomObject (from ConvertFrom-Json) to a hashtable
function ConvertTo-EnvHashtable {
    param($obj)
    $ht = @{}
    if ($obj) { $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value } }
    return $ht
}

$azdEnv = ConvertTo-EnvHashtable (azd env get-values --output json 2>$null | ConvertFrom-Json)
$resourceGroup = $azdEnv['AZURE_RESOURCE_GROUP']
$vmName        = $azdEnv['AZURE_VM_NAME']

if (-not $vmName) {
    Write-Error "AZURE_VM_NAME not found in azd environment. Run from azd-deploy/ directory."
    exit 1
}

Write-Host "Suspending VM: $vmName (resource group: $resourceGroup)"
Write-Host "This will deallocate the VM and stop compute billing."
Write-Host ""

az vm deallocate --resource-group $resourceGroup --name $vmName

Write-Host ""
Write-Host "VM deallocated. Azure resources (Key Vault, Storage, ACR, Arc) remain intact."
Write-Host "Arc-connected K8s registration may go Offline until the VM is resumed."
Write-Host ""
Write-Host "To resume: pwsh scripts/resume.ps1"
