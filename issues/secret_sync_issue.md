# Azure IoT Operations Secret Sync Failure with Federated Identity

## Issue Summary

Secret sync from Azure Key Vault to Kubernetes fails with the following error:

```
AADSTS700211: No matching federated identity record found for presented assertion issuer 
'https://kubernetes.default.svc.cluster.local'. Please check your federated identity 
credential Subject, Audience and Issuer against the presented assertion.
```

The `SecretSync` custom resource shows status `ControllerSyncFailed` and the Kubernetes secret is never created.

## Root Cause

The K3s API server was issuing service account tokens with the **default Kubernetes issuer** (`https://kubernetes.default.svc.cluster.local`), but the federated identity credential in Azure expected tokens with the **Arc OIDC issuer URL** (e.g., `https://northamerica.oic.prod-arc.azure.com/{tenant-id}/{cluster-id}/`).

When the secret-sync controller tries to authenticate to Azure Key Vault using workload identity, it presents a service account token. Azure validates the token's `iss` (issuer) claim against the federated identity credential's issuer URL. Since they didn't match, authentication failed.

## Diagnosis

1. **Check the Arc OIDC issuer URL** (run from Windows or any machine with Azure CLI):
   ```bash
   az connectedk8s show --name <CLUSTER_NAME> --resource-group <RESOURCE_GROUP> \
       --query "oidcIssuerProfile.issuerUrl" --output tsv
   ```
   
   This returns something like:
   ```
   https://northamerica.oic.prod-arc.azure.com/1c1264ca-xxxx-xxxx-xxxx-xxxxxxxxxxxx/62476f3d-xxxx-xxxx-xxxx-xxxxxxxxxxxx/
   ```

2. **Check what issuer K3s is currently using** (run on edge device):
   ```bash
   kubectl cluster-info dump | grep service-account-issuer
   ```
   
   If this returns nothing or shows `https://kubernetes.default.svc.cluster.local`, the K3s API server is not configured with the Arc OIDC issuer.

3. **Check if the K3s config file exists** (run on edge device):
   ```bash
   cat /etc/rancher/k3s/config.yaml
   ```

## Solution

Configure K3s to use the Arc OIDC issuer URL as the service account issuer.

### Step 1: Create/Update K3s Config (on edge device)

First, get your cluster's OIDC issuer URL from Azure (replace with your values):
```bash
# Run this from Windows or any machine with Azure CLI
az connectedk8s show --name <CLUSTER_NAME> --resource-group <RESOURCE_GROUP> \
    --query "oidcIssuerProfile.issuerUrl" --output tsv
```

Then on the edge device, create the config file:
```bash
# Create the config file with YOUR cluster's OIDC issuer URL
sudo tee /etc/rancher/k3s/config.yaml << 'EOF'
kube-apiserver-arg:
  - 'service-account-issuer=<YOUR_OIDC_ISSUER_URL>'
  - 'service-account-max-token-expiration=24h'
EOF
```

Example with actual URL:
```bash
sudo tee /etc/rancher/k3s/config.yaml << 'EOF'
kube-apiserver-arg:
  - 'service-account-issuer=https://northamerica.oic.prod-arc.azure.com/1c1264ca-xxxx-xxxx-xxxx-xxxxxxxxxxxx/62476f3d-xxxx-xxxx-xxxx-xxxxxxxxxxxx/'
  - 'service-account-max-token-expiration=24h'
EOF
```

### Step 2: Restart K3s (on edge device)

```bash
sudo systemctl restart k3s

# Wait for K3s to come back up
sleep 30
kubectl get nodes
```

### Step 3: Verify the Configuration (on edge device)

```bash
kubectl cluster-info dump | grep service-account-issuer
```

You should see the Arc OIDC issuer URL in the output.

### Step 4: Restart the Secret Sync Controller (on edge device)

```bash
kubectl rollout restart deployment -n azure-secret-store

# Wait for restart
sleep 15

# Verify secrets are now syncing
kubectl get secretsync -n azure-iot-operations
kubectl get secret <YOUR_SECRET_NAME> -n azure-iot-operations
```

## Why This Happens

When you connect a K3s cluster to Azure Arc with `--enable-oidc-issuer`, Azure:
1. Generates a unique OIDC issuer URL for your cluster
2. Hosts the public signing keys at that URL
3. Creates federated identity credentials that expect tokens with that issuer

However, the K3s API server doesn't automatically know about this. By default, K3s issues tokens with `https://kubernetes.default.svc.cluster.local` as the issuer. You must explicitly configure K3s to use the Arc OIDC issuer URL.

## Prevention

When setting up a new Arc-enabled K3s cluster for Azure IoT Operations:

1. **Before connecting to Arc**, create the `/etc/rancher/k3s/config.yaml` placeholder
2. **After connecting to Arc**, retrieve the OIDC issuer URL and update the config
3. **Restart K3s** before enabling secret sync or deploying AIO

This step should be added to the `installer.sh` or `arc_enable.ps1` scripts to automate the configuration.

## Proposed Automation Solution

To prevent this issue, the `arc_enable.ps1` script should be enhanced to automatically configure K3s with the correct OIDC issuer URL after Arc connection.

### Recommended Changes to arc_enable.ps1

Add these functions that run **after** `Enable-ArcForCluster` but **before** any workload identity or secret sync operations:

```powershell
function Test-ArcConnectionReady {
    <#
    .SYNOPSIS
        Validates that the Arc connection is fully established and ready.
    
    .DESCRIPTION
        Checks multiple indicators to ensure Arc is ready:
        1. Azure resource exists and shows "Connected" status
        2. OIDC issuer URL is available (not null/empty)
        3. Arc agents are running in the cluster
        
        Returns $true if ready, $false otherwise.
    #>
    
    Write-Log "Checking if Arc connection is ready..."
    
    # Check 1: Azure resource exists and is connected
    try {
        $arcCluster = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName -ErrorAction Stop
        
        if ($arcCluster.ConnectivityStatus -ne "Connected") {
            Write-WarnLog "Arc cluster exists but status is '$($arcCluster.ConnectivityStatus)' (expected 'Connected')"
            return $false
        }
        Write-InfoLog "Arc cluster status: Connected"
    } catch {
        Write-WarnLog "Arc cluster not found in Azure. Run arc_enable.ps1 first."
        return $false
    }
    
    # Check 2: OIDC issuer URL is available
    $oidcIssuerUrl = az connectedk8s show `
        --name $script:ClusterName `
        --resource-group $script:ResourceGroup `
        --query "oidcIssuerProfile.issuerUrl" `
        --output tsv 2>$null
    
    if ([string]::IsNullOrEmpty($oidcIssuerUrl)) {
        Write-WarnLog "OIDC issuer URL not yet available. Arc may still be initializing."
        return $false
    }
    Write-InfoLog "OIDC issuer URL available: $oidcIssuerUrl"
    
    # Check 3: Arc agents are running in the cluster
    $arcPods = kubectl get pods -n azure-arc --no-headers 2>$null
    if (-not $arcPods) {
        Write-WarnLog "No Arc agent pods found in azure-arc namespace"
        return $false
    }
    
    $runningPods = ($arcPods | Select-String -Pattern "Running").Count
    $totalPods = ($arcPods | Measure-Object -Line).Lines
    
    if ($runningPods -lt 5) {
        Write-WarnLog "Only $runningPods of $totalPods Arc pods are Running. Waiting for more pods to start."
        return $false
    }
    Write-InfoLog "Arc agents running: $runningPods pods in Running state"
    
    # Check 4: OIDC issuer is enabled in Arc
    if (-not $arcCluster.OidcIssuerProfileEnabled) {
        Write-WarnLog "OIDC issuer profile is not enabled on the Arc cluster"
        return $false
    }
    Write-InfoLog "OIDC issuer profile enabled: True"
    
    Write-Success "Arc connection is fully ready"
    return $true
}

function Configure-K3sOidcIssuer {
    <#
    .SYNOPSIS
        Configures K3s to use the Arc OIDC issuer URL for service account tokens.
    
    .DESCRIPTION
        After Arc connection, retrieves the OIDC issuer URL from Azure and configures
        K3s to issue service account tokens with that issuer. This is REQUIRED for
        workload identity and secret sync to work properly.
        
        Without this configuration, K3s issues tokens with the default issuer
        'https://kubernetes.default.svc.cluster.local' which doesn't match the
        federated identity credentials created by Azure.
        
        Safe to run multiple times. If Arc is not ready, it exits with 
        instructions to retry.
    #>
    
    Write-Log "Configuring K3s OIDC issuer..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would configure K3s OIDC issuer"
        return $true
    }
    
    # Validate Arc connection is ready
    if (-not (Test-ArcConnectionReady)) {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "ARC CONNECTION NOT READY" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The Arc connection is not fully established yet."
        Write-Host "This can take 2-5 minutes after running arc_enable.ps1."
        Write-Host ""
        Write-Host "Please wait a few minutes and run this script again." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "To check Arc status manually:" -ForegroundColor Gray
        Write-Host "  kubectl get pods -n azure-arc"
        Write-Host "  az connectedk8s show --name $script:ClusterName --resource-group $script:ResourceGroup --query '{status:connectivityStatus, oidc:oidcIssuerProfile.issuerUrl}'"
        Write-Host ""
        return $false
    }
    
    # Get the OIDC issuer URL from the Arc-connected cluster
    Write-InfoLog "Retrieving OIDC issuer URL from Azure..."
    $oidcIssuerUrl = az connectedk8s show `
        --name $script:ClusterName `
        --resource-group $script:ResourceGroup `
        --query "oidcIssuerProfile.issuerUrl" `
        --output tsv
    
    if ([string]::IsNullOrEmpty($oidcIssuerUrl)) {
        Write-ErrorLog "Could not retrieve OIDC issuer URL. Secret sync will fail."
        Write-WarnLog "Manual fix required - see issues/secret_sync_issue.md"
        return $false
    }
    
    Write-InfoLog "OIDC Issuer URL: $oidcIssuerUrl"
    
    # Check if K3s is already configured with the correct issuer
    $currentIssuer = kubectl cluster-info dump 2>$null | Select-String -Pattern "service-account-issuer=([^\s,`"]+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1
    
    if ($currentIssuer -eq $oidcIssuerUrl) {
        Write-Success "K3s already configured with correct OIDC issuer"
        return $true
    }
    
    if ($currentIssuer) {
        Write-InfoLog "Current K3s issuer: $currentIssuer"
        Write-InfoLog "Expected issuer:    $oidcIssuerUrl"
    } else {
        Write-InfoLog "K3s is using default issuer (kubernetes.default.svc.cluster.local)"
    }
    
    Write-InfoLog "Updating K3s configuration..."
    
    # Create the K3s config file content
    $k3sConfig = @"
kube-apiserver-arg:
  - 'service-account-issuer=$oidcIssuerUrl'
  - 'service-account-max-token-expiration=24h'
"@
    
    # Write config file (requires sudo on Linux)
    $configPath = "/etc/rancher/k3s/config.yaml"
    
    # Check if config file exists and has other settings
    $existingConfig = $null
    try {
        $existingConfig = sudo cat $configPath 2>$null
    } catch {}
    
    if ($existingConfig -and $existingConfig -notmatch "service-account-issuer") {
        # Append to existing config
        Write-InfoLog "Appending OIDC issuer to existing K3s config..."
        $k3sConfig = $existingConfig.TrimEnd() + "`n" + $k3sConfig
    }
    
    # Write the config file
    $k3sConfig | sudo tee $configPath > $null
    
    Write-InfoLog "Restarting K3s to apply OIDC issuer configuration..."
    sudo systemctl restart k3s
    
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "K3S OIDC ISSUER CONFIGURED" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "K3s is restarting. This takes 60-90 seconds." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Run this script again to verify the configuration is complete." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To check K3s status manually:" -ForegroundColor Gray
    Write-Host "  kubectl get nodes"
    Write-Host "  kubectl cluster-info dump | grep service-account-issuer"
    Write-Host ""
    
    return $true  # Config written successfully, user should re-run to verify
}
```

### Integration Point

In the `Main` function of `arc_enable.ps1`, add the call after Arc connection:

```powershell
function Main {
    # ... existing code ...
    
    Enable-ArcForCluster
    
    # Configure K3s OIDC issuer - may exit early if Arc not ready
    $oidcConfigured = Configure-K3sOidcIssuer
    if (-not $oidcConfigured) {
        Write-Host ""
        Write-Host "Run this script again in a few minutes to complete OIDC configuration." -ForegroundColor Yellow
        Write-Host ""
        exit 0  # Exit gracefully - user should re-run
    }
    
    Enable-ArcFeatures
    Enable-OidcWorkloadIdentity
    Enable-CustomLocations
    Test-ArcConnection
    Show-Completion
}
```

### Alternative: Bash Script for installer.sh

If the OIDC configuration should happen in the bash installer instead, add these functions to `installer.sh`:

```bash
# Check if Arc connection is fully ready
check_arc_ready() {
    log_info "Checking if Arc connection is ready..."
    
    # Check 1: Arc resource exists in Azure and is connected
    ARC_STATUS=$(az connectedk8s show \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "connectivityStatus" \
        --output tsv 2>/dev/null)
    
    if [ -z "$ARC_STATUS" ]; then
        log_warn "Arc cluster not found in Azure"
        return 1
    fi
    
    if [ "$ARC_STATUS" != "Connected" ]; then
        log_warn "Arc cluster status is '$ARC_STATUS' (expected 'Connected')"
        return 1
    fi
    log_info "Arc cluster status: Connected"
    
    # Check 2: OIDC issuer URL is available
    OIDC_ISSUER=$(az connectedk8s show \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "oidcIssuerProfile.issuerUrl" \
        --output tsv 2>/dev/null)
    
    if [ -z "$OIDC_ISSUER" ]; then
        log_warn "OIDC issuer URL not yet available"
        return 1
    fi
    log_info "OIDC issuer URL available"
    
    # Check 3: Arc agents are running
    RUNNING_PODS=$(kubectl get pods -n azure-arc --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    
    if [ "$RUNNING_PODS" -lt 5 ]; then
        log_warn "Only $RUNNING_PODS Arc pods are Running (need at least 5)"
        return 1
    fi
    log_info "Arc agents running: $RUNNING_PODS pods"
    
    # Check 4: OIDC issuer profile is enabled
    OIDC_ENABLED=$(az connectedk8s show \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "oidcIssuerProfile.enabled" \
        --output tsv 2>/dev/null)
    
    if [ "$OIDC_ENABLED" != "true" ]; then
        log_warn "OIDC issuer profile not enabled"
        return 1
    fi
    log_info "OIDC issuer profile enabled"
    
    log_success "Arc connection is fully ready"
    return 0
}

configure_k3s_oidc_issuer() {
    log_info "Configuring K3s OIDC issuer for workload identity..."
    
    # Validate Arc is ready first
    if ! check_arc_ready; then
        echo ""
        echo "============================================================================"
        echo "ARC CONNECTION NOT READY"
        echo "============================================================================"
        echo ""
        echo "The Arc connection is not fully established yet."
        echo "This can take 2-5 minutes after running arc_enable.ps1."
        echo ""
        echo "Please wait a few minutes and run this script again."
        echo ""
        echo "To check Arc status manually:"
        echo "  kubectl get pods -n azure-arc"
        echo "  az connectedk8s show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP"
        echo ""
        return 1  # Return non-zero but don't exit - let caller decide
    fi
    
    # Get OIDC issuer URL
    OIDC_ISSUER=$(az connectedk8s show \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "oidcIssuerProfile.issuerUrl" \
        --output tsv 2>/dev/null)
    
    if [ -z "$OIDC_ISSUER" ]; then
        log_warn "Could not retrieve OIDC issuer URL"
        log_warn "Secret sync may fail - see issues/secret_sync_issue.md"
        return 1
    fi
    
    log_info "OIDC Issuer URL: $OIDC_ISSUER"
    
    # Check current configuration
    CURRENT_ISSUER=$(kubectl cluster-info dump 2>/dev/null | grep -oP 'service-account-issuer=\K[^\s,"]+' | head -1)
    
    if [ "$CURRENT_ISSUER" = "$OIDC_ISSUER" ]; then
        log_success "K3s already configured with correct OIDC issuer"
        return 0
    fi
    
    if [ -n "$CURRENT_ISSUER" ]; then
        log_info "Current K3s issuer: $CURRENT_ISSUER"
        log_info "Expected issuer:    $OIDC_ISSUER"
    else
        log_info "K3s using default issuer (kubernetes.default.svc.cluster.local)"
    fi
    
    # Create/update K3s config
    log_info "Updating K3s configuration..."
    
    sudo mkdir -p /etc/rancher/k3s
    
    sudo tee /etc/rancher/k3s/config.yaml << EOF
kube-apiserver-arg:
  - 'service-account-issuer=$OIDC_ISSUER'
  - 'service-account-max-token-expiration=24h'
EOF
    
    # Restart K3s
    log_info "Restarting K3s..."
    sudo systemctl restart k3s
    
    echo ""
    echo "============================================================================"
    echo "K3S OIDC ISSUER CONFIGURED"
    echo "============================================================================"
    echo ""
    echo "K3s is restarting. This takes 60-90 seconds."
    echo ""
    echo "Run this script again to verify the configuration is complete."
    echo ""
    echo "To check K3s status manually:"
    echo "  kubectl get nodes"
    echo "  kubectl cluster-info dump | grep service-account-issuer"
    echo ""
    
    return 0  # Config written successfully, user should re-run to verify
}
```

### Workflow Recommendation

The ideal workflow order is:

1. **installer.sh** - Install K3s (without OIDC config yet)
2. **arc_enable.ps1** - Connect to Arc (OIDC issuer URL becomes available)
3. **Configure K3s OIDC** - Update config.yaml and restart K3s (NEW STEP)
4. **External-Configurator.ps1** - Deploy AIO with secret sync enabled

The OIDC configuration **must** happen after Arc connection (step 2) because the issuer URL is generated during Arc enablement and is cluster-specific.

### Run-Until-Success Pattern

The script is designed to be run repeatedly until successful:

```bash
# First run - might exit early if Arc not ready
./arc_enable.ps1

# If it says "Arc not ready", wait and run again
sleep 120
./arc_enable.ps1

# Keep running until you see "OIDC issuer configured" success message
```

Each run will:
1. **Check if Arc is ready** → If not, exit with "try again" message
2. **Check if OIDC is already configured** → If yes, skip to next step
3. **Configure OIDC and restart K3s** → Only if needed

### Safe to Run Repeatedly

The proposed solution is safe to run over and over:
- **Checks state first** - each step verifies current configuration before making changes
- **Early exit if not ready** - doesn't make partial changes
- **Clear messaging** - tells user exactly what to do next
- **Graceful degradation** - continues with other steps if OIDC already configured

### Testing the Automation

After implementing, verify with:

```bash
# Check K3s is using the Arc OIDC issuer
kubectl cluster-info dump | grep service-account-issuer

# Create a test secret sync and verify it works
kubectl get secretsync -n azure-iot-operations
```

## Related Documentation

- [Azure Arc Workload Identity](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/workload-identity)
- [Azure IoT Operations - Enable Secure Settings](https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-enable-secure-settings)
- [Secret Store Extension](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/secret-store-extension)
