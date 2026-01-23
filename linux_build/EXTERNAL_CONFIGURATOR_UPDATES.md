# External-Configurator.ps1 Updates for CSI Secret Store

## Summary of Changes

The `External-Configurator.ps1` script has been updated to verify that the CSI Secret Store driver is installed on the cluster before deploying Azure IoT Operations. This ensures users are aware of secret management capabilities and potential limitations.

## What Was Added

### 1. New Function: `Test-CSISecretStore`

**Location:** After `Test-Prerequisites` function (around line 230)

**Purpose:** Verifies that the CSI Secret Store driver and Azure Key Vault provider are properly installed on the Kubernetes cluster.

**Behavior:**
- ✅ **If CSI Secret Store IS installed:**
  - Displays success message
  - Confirms secret management is enabled
  - Allows deployment to proceed
  - Fabric RTI dataflows will work

- ❌ **If CSI Secret Store is NOT installed:**
  - Displays warning with clear explanation
  - Shows installation commands for the Linux edge device
  - Prompts user to continue or cancel
  - If continued, warns that Fabric RTI will NOT work

**Checks Performed:**
1. Verifies `secrets-store.csi.k8s.io` CSI driver exists
2. Counts CSI driver pods in `kube-system` namespace
3. Counts Azure Key Vault provider pods in `kube-system` namespace

### 2. Integration in Main Flow

**Location:** Main execution function, Phase 5.5 (after Arc enablement, before IoT Operations deployment)

The script now:
1. Checks prerequisites
2. Loads configuration
3. Connects to Azure
4. Initializes kubeconfig
5. Creates Azure resources
6. Enables Arc
7. **→ NEW: Verifies CSI Secret Store** ← 
8. Deploys Azure IoT Operations
9. Verifies deployment
10. Shows summary

### 3. Enhanced Deployment Verification

**Location:** `Test-Deployment` function (around line 1318)

After deployment verification, the script now:
- Re-checks CSI Secret Store status
- Displays clear message about secret management availability
- Indicates whether Fabric RTI dataflows will work

## User Experience

### Scenario 1: CSI Secret Store Installed

```
============================================================================
Checking for Secret Management Prerequisites
============================================================================
✓ CSI Secret Store driver installed (3 pod(s))
✓ Azure Key Vault provider installed (2 pod(s))
Secret management is enabled - Fabric RTI dataflows will work

[Deployment proceeds...]
```

### Scenario 2: CSI Secret Store Missing

```
============================================================================
Checking for Secret Management Prerequisites
============================================================================

⚠️  WARNING: CSI Secret Store driver is NOT installed

This means:
  ❌ Secret management will NOT be available
  ❌ Fabric Real-Time Intelligence dataflows will NOT work
  ❌ Azure Key Vault integration will be disabled

To fix this, run on your Linux edge device:

  helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
  helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
  helm repo update

  helm install csi-secrets-store-driver secrets-store-csi-driver/secrets-store-csi-driver \
      --namespace kube-system \
      --set syncSecret.enabled=true \
      --set enableSecretRotation=true

  helm install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
      --namespace kube-system

Or use the updated linux_installer.sh which includes CSI Secret Store installation.

See: linux_build\CSI_SECRET_STORE_SETUP.md for details

Continue without secret management? (y/N):
```

If user types `y`:
```
Continuing without secret management - Fabric RTI will NOT be available
[Deployment proceeds with warning...]
```

If user types `n` or anything else:
```
Deployment cancelled. Please install CSI Secret Store first.
[Script exits with error]
```

## Why These Changes Matter

### Before These Changes
- ❌ Azure IoT Operations would deploy successfully
- ❌ User wouldn't know secret management was missing
- ❌ Fabric RTI dataflows would fail mysteriously
- ❌ Portal would show confusing errors
- ❌ No clear path to resolution

### After These Changes
- ✅ User is informed BEFORE deployment
- ✅ Clear explanation of what's missing
- ✅ Exact commands provided to fix the issue
- ✅ User can make informed decision
- ✅ No surprises after deployment

## Testing the Changes

### Test 1: Cluster WITH CSI Secret Store

```powershell
.\External-Configurator.ps1 -ClusterInfo cluster_info.json
```

Expected: Script shows green checkmarks, proceeds with deployment.

### Test 2: Cluster WITHOUT CSI Secret Store

```powershell
.\External-Configurator.ps1 -ClusterInfo cluster_info.json
```

Expected: Script shows warning, prompts user, provides installation commands.

### Test 3: Verification After Deployment

Check the deployment verification output at the end:
- Should show CSI Secret Store status
- Should indicate if Fabric RTI is available

## Integration with Other Files

This change works with:

1. **[linux_installer.sh](linux_installer.sh)** - Now installs CSI Secret Store automatically
2. **[CSI_SECRET_STORE_SETUP.md](CSI_SECRET_STORE_SETUP.md)** - Referenced in warning messages
3. **[verify-csi-secret-store.sh](verify-csi-secret-store.sh)** - Can be run independently for verification

## Backwards Compatibility

✅ **Fully backwards compatible** - The script will continue to work with:
- Clusters that already have CSI Secret Store
- Clusters without CSI Secret Store (with user acknowledgment)
- Existing configuration files
- Existing workflows

The only change is the additional verification and user notification.

## Future Enhancements

Potential improvements for future versions:

1. **Automatic Installation:** Add option to automatically install CSI Secret Store from the PowerShell script
2. **Detailed Diagnostics:** Show CSI driver pod logs if verification fails
3. **Configuration Validation:** Check CSI driver configuration settings
4. **Post-Deployment Testing:** Verify secret mounting actually works
5. **ARM Template Integration:** Include CSI Secret Store in ARM deployment templates

## Related Documentation

- [CSI_SECRET_STORE_SETUP.md](CSI_SECRET_STORE_SETUP.md) - Complete setup guide
- [verify-csi-secret-store.sh](verify-csi-secret-store.sh) - Verification script
- [External-Configurator-README.md](External-Configurator-README.md) - Main documentation
