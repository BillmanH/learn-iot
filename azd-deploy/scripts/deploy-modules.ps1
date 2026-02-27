# ==============================================================================
# deploy-modules.ps1
# Builds, pushes, and deploys selected edge modules to the AIO cluster.
# Called by post-provision.ps1 or can be run standalone for re-deploys.
#
# Usage (standalone):
#   azd env set DEPLOY_MODULE_EDGEMQTTSIM true
#   pwsh scripts/deploy-modules.ps1
#
# Usage (re-deploy a single module):
#   pwsh scripts/deploy-modules.ps1 -OnlyModule edgemqttsim
# ==============================================================================

param(
    [hashtable]$DeployFlags,   # Passed in by post-provision.ps1
    [string]$AcrServer,        # ACR login server (e.g. myacr.azurecr.io)
    [string]$OnlyModule,       # If set, deploy only this module regardless of flags
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load azd env if not called from post-provision
# ---------------------------------------------------------------------------
if (-not $AcrServer) {
    $azdEnv = (azd env get-values --output json 2>$null | ConvertFrom-Json -AsHashtable)
    $AcrServer = $azdEnv['AZURE_CONTAINER_REGISTRY_LOGIN_SERVER']
    $resourceGroup = $azdEnv['AZURE_RESOURCE_GROUP']
    $acrName = $azdEnv['AZURE_CONTAINER_REGISTRY_NAME']
}

if (-not $AcrServer) {
    Write-Error "AZURE_CONTAINER_REGISTRY_LOGIN_SERVER not set. Run azd provision first."
    exit 1
}

if (-not $DeployFlags) {
    $azdEnv = $azdEnv ?? (azd env get-values --output json 2>$null | ConvertFrom-Json -AsHashtable)
    $DeployFlags = @{
        'edgemqttsim'   = ($azdEnv['DEPLOY_MODULE_EDGEMQTTSIM'] -eq 'true')
        'sputnik'       = ($azdEnv['DEPLOY_MODULE_SPUTNIK'] -eq 'true')
        'hello-flask'   = ($azdEnv['DEPLOY_MODULE_HELLO_FLASK'] -eq 'true')
        'demohistorian' = ($azdEnv['DEPLOY_MODULE_DEMOHISTORIAN'] -eq 'true')
    }
}

# Override with -OnlyModule
if ($OnlyModule) {
    $DeployFlags = @{ $OnlyModule = $true }
}

# ---------------------------------------------------------------------------
# Module definitions: folder -> image tag + K8s deployment YAML path
# Paths are relative to the repo root
# ---------------------------------------------------------------------------
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
$modules = @{
    'edgemqttsim'   = @{ Folder = 'modules/edgemqttsim';   ImageTag = 'edgemqttsim:latest' }
    'sputnik'       = @{ Folder = 'modules/sputnik';       ImageTag = 'sputnik:latest'       }
    'hello-flask'   = @{ Folder = 'modules/hello-flask';   ImageTag = 'hello-flask:latest'   }
    'demohistorian' = @{ Folder = 'modules/demohistorian'; ImageTag = 'demohistorian:latest'  }
}

# ---------------------------------------------------------------------------
# ACR login
# ---------------------------------------------------------------------------
Write-Host "Logging in to ACR: $AcrServer"
if (-not $DryRun) {
    az acr login --name ($AcrServer -split '\.')[0]
}

# ---------------------------------------------------------------------------
# Build, push, deploy each enabled module
# ---------------------------------------------------------------------------
foreach ($moduleName in $modules.Keys) {
    if (-not $DeployFlags[$moduleName]) { continue }

    $mod = $modules[$moduleName]
    $folder = Join-Path $repoRoot $mod.Folder
    $imageRef = "$AcrServer/$($mod.ImageTag)"
    $deployYaml = Join-Path $folder 'deployment.yaml'

    Write-Host ""
    Write-Host "=== Module: $moduleName ==="

    if (-not (Test-Path $folder)) {
        Write-Warning "  Module folder not found: $folder - skipping."
        continue
    }

    # Build
    Write-Host "  Building Docker image..."
    if (-not $DryRun) {
        docker build -t $imageRef $folder
    }

    # Push
    Write-Host "  Pushing to ACR: $imageRef"
    if (-not $DryRun) {
        docker push $imageRef
    }

    # Deploy (via kubectl through connectedk8s proxy or direct kubeconfig)
    if (Test-Path $deployYaml) {
        # Substitute ACR server in deployment YAML
        $yamlContent = Get-Content $deployYaml -Raw
        $yamlContent = $yamlContent -replace '\$\{ACR_SERVER\}', $AcrServer
        $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
        $yamlContent | Set-Content $tmpYaml

        Write-Host "  Applying deployment.yaml..."
        if (-not $DryRun) {
            kubectl apply -f $tmpYaml
        }
        Remove-Item $tmpYaml -Force
    } else {
        Write-Warning "  No deployment.yaml found at $deployYaml - image pushed but not deployed to K8s."
    }

    Write-Host "  $moduleName deployed."
}

Write-Host ""
Write-Host "=== Module deployment complete ==="
