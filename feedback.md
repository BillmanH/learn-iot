

# Change Spec: User Feedback Implementation

## Status: ✅ Implementation Complete

---

## Implementation Phases

| Phase | Scope | Status |
|-------|-------|--------|
| **1** | Create `external_configuration/session-bootstrap.ps1` | ✅ complete |
| **2** | All changes to `external_configuration/External-Configurator.ps1` | ✅ complete |
| **3** | All changes to `external_configuration/grant_entra_id_roles.ps1` | ✅ complete |
| **4** | All changes to `readme.md` | ✅ complete |
| **5** | Arc Gateway GA updates — `README_ADVANCED.md`, `arc_build_linux/linux_build_steps.md` | ✅ complete |

### Phase Details

**Phase 1 — New file** *(no risk to existing code)*
- Create `external_configuration/session-bootstrap.ps1` → item 9

**Phase 2 — `External-Configurator.ps1`** *(all changes in one pass)*
- PS7 version warning → item 1
- az CLI minimum version warning `>= 2.64.0` → item 5
- Stop auto-upgrading `azure-iot-ops` extension, warn instead → item 5
- `cluster_info.json` optional — downgrade fatal to warn → item 7
- `Test-ConfigConsistency` null guard for `$script:ClusterData` → item 7
- `-DemoMode` switch + broker sizing flags on `az iot ops create` → item 8
- `$env:AZURE_*` fallback loading with INFO/WARN/ERROR tiers → item 9

**Phase 3 — `grant_entra_id_roles.ps1`** *(mirrors pattern from Phase 2)*
- PS7 version warning → item 1
- `$env:AZURE_*` fallback loading with INFO/WARN/ERROR tiers → item 9

**Phase 4 — `readme.md`** *(all changes in one pass)*
- PS7 download link in prerequisites → item 1
- GitHub .zip download instructions → item 3
- AKS-EE entry point callout with new MS Learn link, replacing old GitHub link → item 4
- az CLI prerequisites section with version check and upgrade steps → item 5
- Execution policy note → item 6
- `-DemoMode` flag documentation → item 8
- "Single Windows Machine (AKS-EE)" quickstart section with `session-bootstrap.ps1` → item 9

**Phase 5 — Secondary docs** *(Arc Gateway GA)*
- `README_ADVANCED.md` — find and update all Preview references → item 2
- `arc_build_linux/linux_build_steps.md` — find and update all Preview references → item 2
- Pull current canonical GA link from MS Learn during this phase → item 2

---

## 1. Require PowerShell 7

**Type**: Docs + Code
**Files**: `readme.md`, `external_configuration/External-Configurator.ps1`, `external_configuration/grant_entra_id_roles.ps1`

### Changes
- `readme.md` Prerequisites section: Add PS7 requirement with download link
- `External-Configurator.ps1` `Test-Prerequisites`: Change minimum version check from `Major -lt 5` to `Major -lt 7`; on failure, print a warning and the PS7 download link, then continue — do not hard-stop. Message: *"WARNING: You are running PowerShell $psVersion. This may cause unexpected errors. PowerShell 7 is strongly recommended. Download: https://aka.ms/install-powershell"*
- `grant_entra_id_roles.ps1`: No version check exists at all — add the same PS7 warning at the top of the script

---

## 2. Arc Gateway — Remove "Preview" Label

**Type**: Docs
**Files**: `readme.md`, `README_ADVANCED.md`, `arc_build_linux/linux_build_steps.md` (check all three)

### Changes
- Find all references to Arc Gateway being in "Preview"
- Update language to reflect GA status
- Update any links that point to preview-era MS Learn pages

### Open Question
> **Q2**: Should the updated docs link to a specific MS Learn GA page for Arc Gateway? If yes, do you have the preferred URL, or should I pull the current canonical one from the docs?

---

## 3. GitHub Download Instructions

**Type**: Docs
**Files**: `readme.md`

### Changes
- In the "Clone Repository" section, add a .zip download option before the `git clone` instructions
- Suggested language: *"If you're not using Git, click the green **Code** button on GitHub and choose **Download ZIP**, then extract to a local working directory."*

---

## 4. AKS-EE Entry Point Callout

**Type**: Docs
**Files**: `readme.md`

### Background
AKS-EE users complete their edge setup via the MS Learn guide, then jump directly to step 4. The current `readme.md` links to the old GitHub-hosted AKS-EE quickstart script — replace it with the official MS Learn page.

**AKS-EE reference**: [Deploy Azure IoT Operations on AKS Edge Essentials](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot)

### Changes
- Replace the existing AKS-EE link in `readme.md` with the MS Learn URL above
- Add a prominent callout block near the top of the Quick Start section, e.g.:
  > **Using AKS Edge Essentials (Windows-based edge)?** Follow [this guide](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot) to set up your edge cluster, then **skip to step 4** (Azure Configuration from Windows Machine) below. Steps 1–3b do not apply.

---

## 5. Azure CLI Setup Steps (Windows Prerequisites)

**Type**: Docs + Code
**Files**: `readme.md`, `external_configuration/External-Configurator.ps1`

### Changes
- `readme.md`: Add a Windows Prerequisites section (or expand the existing one) with:
  - Install Azure CLI — [aka.ms/installazurecliwindows](https://aka.ms/installazurecliwindows)
  - **Minimum version: 2.64.0** — Check with `az --version`; update the CLI itself with `az upgrade`
  - Check extension version: `az extension show --name azure-iot-ops`
  - Manual extension update: `az extension update --name azure-iot-ops` (do **not** let scripts auto-upgrade)
  - Add `connectedk8s` extension: `az extension add --upgrade --name connectedk8s`
  - Login step: `az login --tenant <tenant-id>`, then `az account set --subscription <sub-id>`
- `External-Configurator.ps1` `Test-Prerequisites`: Currently checks `az version` but does not enforce a minimum. Add a check for `>= 2.64.0`; on failure, warn and continue — do not block. Message: *"WARNING: Azure CLI $azVersion detected. Version 2.64.0 or newer is recommended. If you encounter errors, upgrade first: az upgrade"*

---

## 6. Execution Policy Note

**Type**: Docs
**Files**: `readme.md`

### Changes
- Add a short note in the Windows Prerequisites or step 4 section:
  Since these scripts are unsigned, run this in your PowerShell session before executing any `.ps1` file:
  ```powershell
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
  ```

---

## 7. `cluster_info.json` Should Be Optional

**Type**: Code (Bug Fix)
**Files**: `external_configuration/External-Configurator.ps1`

### Background
The script currently hard-stops (`-Fatal`) if `config/cluster_info.json` is not found. A user who starts from the Windows machine side (e.g., AKS-EE path) may not have this file yet and should not be completely blocked.

**Audit result**: `cluster_info.json` provides two things to the script:
1. `cluster_name` — also available from `aio_config.json` (`cluster_name` field), which the script already uses as a fallback in `Test-ConfigConsistency`
2. Display-only info (`node_name`, `node_ip`, `kubernetes_version`, etc.) — printed to console, used in no downstream logic

**The file is not required.** The fix is straightforward.

### Changes
- `Import-ClusterInfo`: if the file is not found, `Write-WarnLog` instead of `-Fatal` exit; set `$script:ClusterData = $null` and continue
- `Test-ConfigConsistency`: guard the `$script:ClusterData.cluster_name` access with a null check; if null, skip cross-validation and use `$script:ConfigClusterName` from `aio_config.json` directly

---

## 8. Reduce MQTT Broker RAM / Replica Count for Demo Machines

**Type**: Research + Code/Config
**Files**: `external_configuration/External-Configurator.ps1` (likely), possibly a new `BrokerSpec` manifest

### Background
The default AIO MQTT broker deployment uses multiple frontend and backend replicas, which is excessive for a single-node demo machine. The user wants a lighter configuration to reduce RAM usage.

**Reference**: [Configure broker settings for high availability, scaling, and memory usage](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-availability-scale)

### Demo Mode Definition

The `az iot ops create` command accepts direct broker sizing flags. A `-DemoMode` switch in `External-Configurator.ps1` would add these flags to the existing `az iot ops create` call:

| Flag | Default (production) | Demo Mode value | Notes |
|------|----------------------|-----------------|-------|
| `--broker-frontend-replicas` | 2 | **1** | Single frontend pod |
| `--broker-frontend-workers` | 2 | **1** | 1 CPU core max |
| `--broker-backend-part` | 2 | **1** | Single partition |
| `--broker-backend-rf` | 2 | **2** | Cannot go below 2 — hard requirement |
| `--broker-backend-workers` | 2 | **1** | 1 backend worker |
| `--broker-mem-profile` | Medium | **Tiny** | ~99 MiB/frontend, ~102 MiB/backend |

**Estimated RAM with demo mode** (Tiny profile formula: `R_fe * M_fe + (P_be * RF_be) * M_be * W_be`):
`1 * 99 MiB + (1 * 2) * 102 MiB * 1` = **~303 MiB** total broker RAM

**Estimated RAM with defaults** (Medium profile, 2 replicas, 2 partitions, RF=2):
`2 * 1.9 GB + (2 * 2) * 1.5 GB * 2` = **~15.8 GB**

### Changes
- Add `-DemoMode` switch parameter to `External-Configurator.ps1`
- When `-DemoMode` is set, append the five flags above to the `az iot ops create` call
- Print a visible warning when `-DemoMode` is active: *"Demo mode enabled — broker is configured for minimal RAM, not suitable for production"*
- Document the flag in `readme.md`

> **Note**: `-DemoMode` as an opt-in flag (not the new default) is the right call — production users should not silently get an under-resourced broker.

---

## 9. AKS-EE Single-Machine Session Bootstrap (Zero-JSON Workflow)

**Type**: Docs + New Script
**Files**: `readme.md`, new `external_configuration/session-bootstrap.ps1`

### Background
The target persona here is a user on a **single Windows laptop** running both AKS-EE (edge) and az CLI (development environment) on the same machine, in the same PS7 session. They want to:
- Fill in their details **once** at the top of a script block
- Copy-paste the rest without editing any JSON files
- Never re-enter `subscriptionId`, `tenantId`, `clusterName`, etc. across multiple scripts
- Have `External-Configurator.ps1`, `grant_entra_id_roles.ps1`, and `AksEdgeQuickStartForAio.ps1` all pick up the same values automatically

### Changes

**1. New file: `external_configuration/session-bootstrap.ps1`** (run from the `external_configuration/` folder before any other script in that folder)

Sets both `$global:*` variables (consumed by `AksEdgeQuickStartForAio.ps1`) and `$env:AZURE_*` variables (consumed by az CLI and our scripts). Users fill in the blank strings at the top and run it once:

```powershell
# ------------------------------- 
# REQUIRED: Fill these in once
# -------------------------------
$AZ_SUBSCRIPTION_ID    = ""   # az account list -o table
$AZ_TENANT_ID          = ""   # az account show --query tenantId
$AZ_LOCATION           = ""   # e.g. eastus2
$AZ_RESOURCE_GROUP     = ""   # will be created if it doesn't exist
$AKS_EDGE_CLUSTER_NAME = ""   # must be lowercase, no spaces
$CUSTOM_LOCATIONS_OID  = ""   # az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
$WORKDIR               = ""   # e.g. C:\workingdir (optional)

# ------------------------------- 
# DO NOT EDIT BELOW THIS LINE
# -------------------------------
if ($WORKDIR -and (Test-Path $WORKDIR)) { Set-Location $WORKDIR }

# Global vars for AksEdgeQuickStartForAio.ps1
$global:SubscriptionId    = $AZ_SUBSCRIPTION_ID
$global:TenantId          = $AZ_TENANT_ID
$global:Location          = $AZ_LOCATION
$global:ResourceGroupName = $AZ_RESOURCE_GROUP
$global:ClusterName       = $AKS_EDGE_CLUSTER_NAME
$global:CustomLocationOID = $CUSTOM_LOCATIONS_OID

# Env vars for az CLI and our scripts
$env:AZURE_SUBSCRIPTION_ID = $AZ_SUBSCRIPTION_ID
$env:AZURE_TENANT_ID       = $AZ_TENANT_ID
$env:AZURE_LOCATION        = $AZ_LOCATION
$env:AZURE_RESOURCE_GROUP  = $AZ_RESOURCE_GROUP
$env:AKSEDGE_CLUSTER_NAME  = $AKS_EDGE_CLUSTER_NAME
$env:CUSTOM_LOCATIONS_OID  = $CUSTOM_LOCATIONS_OID

# Log in
az login --tenant $AZ_TENANT_ID | Out-Null
az account set --subscription $AZ_SUBSCRIPTION_ID
Write-Host "Session ready. Subscription: $AZ_SUBSCRIPTION_ID" -ForegroundColor Green
```

**2. `External-Configurator.ps1` and `grant_entra_id_roles.ps1`**: Update config loading to check `$env:AZURE_SUBSCRIPTION_ID`, `$env:AZURE_RESOURCE_GROUP`, etc. as fallbacks before prompting the user, so the session bootstrap values are picked up automatically without editing `aio_config.json`.

**3. `readme.md`**: Add a "Single Windows Machine (AKS-EE)" quickstart section and mention `session-bootstrap.ps1` in the `external_configuration/` directory listing. The workflow:
- Step 1: Install prerequisites (PS7, az CLI ≥ 2.64.0, extensions)
- Step 2: `cd external_configuration` then run `.\session-bootstrap.ps1` (fill in 6 values, run once)
- Step 3: Run AKS-EE quickstart
- Step 4: Run `.\grant_entra_id_roles.ps1` then `.\External-Configurator.ps1`

**Behavior for env var overrides**: Three tiers depending on whether a value is present and whether it has a default:

| Situation | Output |
|-----------|--------|
| Value found in `$env:AZURE_*` | `[INFO] Using environment variable AZURE_SUBSCRIPTION_ID: xxxxxxxx-...` |
| Value not found, fallback default available | `[WARN] AZURE_LOCATION not set — using default: eastus` |
| Value not found, no default, required | `[ERROR] AZURE_SUBSCRIPTION_ID is required. Set it in session-bootstrap.ps1 or pass -SubscriptionId.` (then exit) |

This applies to all `$env:AZURE_*` values consumed by `External-Configurator.ps1` and `grant_entra_id_roles.ps1`.

---
<!-- original raw feedback:

Docs – on mslearn Arc Gateway is no longer a “Preview”
* update preview and replace with GA versions



Recommend how to DOWNLOAD files from GitHub (just tell people to grab the .zip from the Code download and extract to a local working directory -- if they know how to clone..they'll do that instead)
* update readme.md to reflect downloading .zip


-	Put a BIG NOTE in the doc where they should START if they used the AKS-EE script instead of the Ubuntu one...don't make them hunt for it.

For the windows machine only:
-	Missing step docs: You need to install az CLI (check versions of CLI and extensions are up to date)  Run az login --tenant <t> 
* for process that use cli, check the version. Don't auto upgrade, give the user steps to upgrade and verify version. 

+ You need to set execution Policy exception because PS1 isn't signed:  Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force


- 	run only .\grant_entra_id_roles.ps1
- 	BUG: must create this: C:\workingdirbill\config\cluster_info.json, then can run .\External-Configurator.ps1  -- file should be optoinal
-->





