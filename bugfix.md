# Bug Report — External Configuration Scripts

Captured from a real run on 2026-03-11. Issues are numbered to match the original notes.

---

## Design Decision — Consistent value resolution order (all Windows scripts)

All scripts that run on a Windows management machine (`grant_entra_id_roles.ps1`,
`External-Configurator.ps1`) must resolve each required value in this order:

1. **Environment variables** — checked first (`$env:AKSEDGE_CLUSTER_NAME`, `$env:AZURE_RESOURCE_GROUP`, etc.)
2. **Config file** — `aio_config.json` / `cluster_info.json` — checked second, overrides env vars only if the env var is absent
3. **CLI parameters** — `-ClusterName`, `-ResourceGroup`, etc. — always win, applied on top of whatever was resolved
4. **Interactive prompt** — last resort only, printed after confirming all three sources were exhausted
5. **Persist the prompted value** as an env var so re-runs and subsequent scripts in the sequence don't re-ask

This makes `$env:*` the fastest zero-config path (paste-and-run scenario from README Option A)
and `aio_config.json` the preferred persistent path.

---

## ~~Bug 1 — AKS-EE: AIDE files required even when global env vars are set~~ **WON'T FIX** (external team)

**Symptom**: The AKS-EE quickstart script (`AksEdgeQuickStartForAio.ps1`) does not pick up
globally-set environment variables and still requires the `aio-aide-userconfig.json` and
`aio-aksedge-config.json` AIDE config files to be present and correctly filled in.

**Reproduced by**: Setting `$env:AKSEDGE_CLUSTER_NAME`, `$env:AZURE_RESOURCE_GROUP`, etc. at
global scope, then running the AKS-EE quickstart — parameters were not picked up without the JSON
files.

**Files affected**: `arc_build_linux/` or AKS-EE quickstart (external Microsoft script)

**Notes / Questions**:
- Is this a limitation of the Microsoft-owned quickstart script that we can't fix?
- Can we document this clearly in the AKS-EE path section of the README so users know to
  always prepare the AIDE files even if env vars are set?

---

## ~~Bug 2 — AKS-EE: `$location` must be added manually to the quickstart command~~ **WON'T FIX** (external team)

**Symptom**: The AKS-EE quickstart command is missing `$location` and fails or silently uses a
wrong default.

**Notes**: `AksEdgeQuickStartForAio.ps1` is owned by another team. Any fix to how it handles
`$location` must go through them. Our scripts cannot change this behaviour.

---

## Bug 3 — AKS-EE file download: cut-and-paste from README does not work

**Symptom**: The README instructions for downloading the AKS-EE quickstart files did not work when
copy-pasted. The user had to manually construct the download commands:

```powershell
$giturl = "https://raw.githubusercontent.com/Azure/AKS-Edge/main/tools"
$url = "$giturl/scripts/AksEdgeQuickStart/AksEdgeQuickStartForAio.ps1"
Invoke-WebRequest -Uri $url -OutFile .\AksEdgeQuickStartForAio.ps1 -UseBasicParsing
Invoke-WebRequest -Uri "$giturl/aio-aide-userconfig.json" -OutFile .\aio-aide-userconfig.json -UseBasicParsing
Invoke-WebRequest -Uri "$giturl/aio-aksedge-config.json" -OutFile .\aio-aksedge-config.json -UseBasicParsing
Unblock-File .\AksEdgeQuickStartForAio.ps1
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
```

**Likely cause**: Line-break formatting in the README rendered improperly, collapsing multi-line
commands into a single malformed string.

**Fix needed**: Replace the vague reference to "follow the MS docs guide" with an explicit download code block in [readme.md](readme.md) under **Path B / Step 2**:

```powershell
# Download AKS-EE quickstart files
$giturl = "https://raw.githubusercontent.com/Azure/AKS-Edge/main/tools"
Invoke-WebRequest -Uri "$giturl/scripts/AksEdgeQuickStart/AksEdgeQuickStartForAio.ps1" `
    -OutFile .\AksEdgeQuickStartForAio.ps1 -UseBasicParsing
Invoke-WebRequest -Uri "$giturl/aio-aide-userconfig.json" `
    -OutFile .\aio-aide-userconfig.json -UseBasicParsing
Invoke-WebRequest -Uri "$giturl/aio-aksedge-config.json" `
    -OutFile .\aio-aksedge-config.json -UseBasicParsing
Unblock-File .\AksEdgeQuickStartForAio.ps1
```

Also add a note that env vars are **not** picked up by the AKS-EE quickstart — the AIDE JSON files must be filled in manually (see Bug 1).

---

## Bug 4 — `grant_entra_id_roles.ps1` prompts for values even when env vars are set

**Symptom**: After setting env vars via the README Option A instructions, running
`grant_entra_id_roles.ps1` still prompts interactively for `Resource Group` and `Cluster name`.

**Root cause (confirmed in code)**: The script checks env vars *after* it has already prompted.
Order in `grant_entra_id_roles.ps1`:

1. Load `aio_config.json` (if found)
2. Override with `-ClusterName` / `-ResourceGroup` command-line params
3. **Prompt user for any still-missing values** ← happens here  
4. *Then* check `$env:AZURE_RESOURCE_GROUP`, `$env:AKSEDGE_CLUSTER_NAME` ← too late

So if `aio_config.json` is absent and no CLI params are passed, the user is prompted before
env vars are consulted. The env var check should move to **before** the prompt, or the prompt
should be the last resort after all three sources are exhausted.

**File**: `external_configuration/grant_entra_id_roles.ps1` (~lines 216–232)

**Same bug exists in**: `External-Configurator.ps1` — same priority ordering issue.

**Proposed fix** — rewrite value resolution in both scripts to follow the standard order (see Design Decision above):

```powershell
# 1. Env vars first
if (-not $script:ResourceGroup)   { $script:ResourceGroup  = $env:AZURE_RESOURCE_GROUP }
if (-not $script:ClusterName)     { $script:ClusterName    = $env:AKSEDGE_CLUSTER_NAME }
if (-not $script:SubscriptionId)  { $script:SubscriptionId = $env:AZURE_SUBSCRIPTION_ID }
if (-not $script:Location)        { $script:Location       = $env:AZURE_LOCATION }

# 2. Config file fills in anything still missing
$configPath = Join-Path $script:ConfigDir "aio_config.json"
Write-Host "[CONFIG] Looking for aio_config.json at: $configPath" -ForegroundColor Gray
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not $script:ResourceGroup)  { $script:ResourceGroup  = $cfg.azure.resource_group }
    if (-not $script:ClusterName)    { $script:ClusterName    = $cfg.azure.cluster_name }
    if (-not $script:SubscriptionId) { $script:SubscriptionId = $cfg.azure.subscription_id }
    if (-not $script:Location)       { $script:Location       = $cfg.azure.location }
} else {
    Write-Warning "[CONFIG] Not found: $configPath"
}

# 3. CLI params always win (applied last, before prompt)
if ($PSBoundParameters.ContainsKey('ResourceGroup')) { $script:ResourceGroup = $ResourceGroup }
if ($PSBoundParameters.ContainsKey('ClusterName'))   { $script:ClusterName   = $ClusterName }

# 4. Prompt only as last resort
if ([string]::IsNullOrEmpty($script:ResourceGroup)) {
    Write-Warning "[INPUT] AZURE_RESOURCE_GROUP not found in env vars or config."
    $script:ResourceGroup = Read-Host "Enter Resource Group name"
    $env:AZURE_RESOURCE_GROUP = $script:ResourceGroup
    Write-Host "[INPUT] Saved as `$env:AZURE_RESOURCE_GROUP for this session." -ForegroundColor Cyan
}
if ([string]::IsNullOrEmpty($script:ClusterName)) {
    Write-Warning "[INPUT] AKSEDGE_CLUSTER_NAME not found in env vars or config."
    $script:ClusterName = Read-Host "Enter Cluster name"
    $env:AKSEDGE_CLUSTER_NAME = $script:ClusterName
    Write-Host "[INPUT] Saved as `$env:AKSEDGE_CLUSTER_NAME for this session." -ForegroundColor Cyan
}
```

Apply the same pattern to `External-Configurator.ps1` (`Connect-ToAzure` / `Import-AzureConfig` functions). Note that Bug 6 (persist prompted value) is folded into step 4 here.

---

## Bug 5 — Scripts don't log *why* they are asking / what they checked

**Symptom**: The user received an interactive prompt with no explanation of what the script tried
before giving up, making it hard to diagnose whether env vars were set correctly.

**Requested behaviour**:
- When `aio_config.json` is not found: log the full path that was searched, e.g.
  `"Looking for aio_config.json at C:\...\config\aio_config.json — not found"`
- When checking env vars by name: log each one, e.g.
  `"Checking $env:AZURE_RESOURCE_GROUP — not set"` / `"Found: rg-my-iot"`
- Only prompt after confirming both sources were exhausted

**Files affected**: `grant_entra_id_roles.ps1`, `External-Configurator.ps1`

**Proposed fix** — in both scripts, instrument every resolution step:

```powershell
# After loading aio_config.json
Write-Host "[CONFIG] Searching for aio_config.json at: $configPath" -ForegroundColor Gray
if (-not (Test-Path $configPath)) {
    Write-Warning "[CONFIG] Not found: $configPath"
} else {
    Write-Host "[CONFIG] Loaded: $configPath" -ForegroundColor Green
}

# When checking each env var
$envVars = @{
    'AZURE_RESOURCE_GROUP'  = 'script:ResourceGroup'
    'AKSEDGE_CLUSTER_NAME'  = 'script:ClusterName'
    'AZURE_SUBSCRIPTION_ID' = 'script:SubscriptionId'
}
foreach ($varName in $envVars.Keys) {
    $val = [System.Environment]::GetEnvironmentVariable($varName)
    if ($val) {
        Write-Host "[ENV] $varName = $val" -ForegroundColor Cyan
    } else {
        Write-Host "[ENV] $varName — not set" -ForegroundColor Gray
    }
}

# Before prompting
Write-Warning "[INPUT] $valueName not found in config file or environment — prompting."
```

---

## Bug 6 — Prompted values are not persisted; user is asked again on re-run

**Symptom**: After answering an interactive prompt, the value is lost when the script exits. On
re-run (or when running the next script in the sequence) the same prompt appears again.

**Requested behaviour**: After accepting user input as a final fallback, immediately write it to
an environment variable *and* confirm to the user:
```
[INPUT] Cluster name entered: my-cluster
        Saving as $env:AKSEDGE_CLUSTER_NAME for this session.
```
This avoids repeating prompts across the two-script workflow
(`grant_entra_id_roles.ps1` → `External-Configurator.ps1`).

**Files affected**: `grant_entra_id_roles.ps1`, `External-Configurator.ps1`

**Proposed fix** — wrap each `Read-Host` to persist the result as an env var immediately:

```powershell
if ([string]::IsNullOrEmpty($script:ResourceGroup)) {
    Write-Warning "[INPUT] AZURE_RESOURCE_GROUP not found in config or environment."
    $script:ResourceGroup = Read-Host "Enter Resource Group name"
    $env:AZURE_RESOURCE_GROUP = $script:ResourceGroup
    Write-Host "[INPUT] Saved as `$env:AZURE_RESOURCE_GROUP for this session." -ForegroundColor Cyan
}

if ([string]::IsNullOrEmpty($script:ClusterName)) {
    Write-Warning "[INPUT] AKSEDGE_CLUSTER_NAME not found in config or environment."
    $script:ClusterName = Read-Host "Enter Cluster name"
    $env:AKSEDGE_CLUSTER_NAME = $script:ClusterName
    Write-Host "[INPUT] Saved as `$env:AKSEDGE_CLUSTER_NAME for this session." -ForegroundColor Cyan
}
```

Apply the same pattern in `External-Configurator.ps1`.

---

## Bug 7 — Fatal error: `cluster_info.json is missing cluster_name` on AKS-EE path

**Symptom (from log)**:

```
Cluster Information:
  Cluster Name:              ← all fields blank
  Node Name:
  Node IP:
  ...
SUCCESS: Cluster information loaded from: C:\workingdir311\learn-iot\config\cluster_info.json
WARNING: Config file not found: C:\workingdir311\learn-iot\config\aio_config.json
ERROR: cluster_info.json is missing cluster_name
Fatal error encountered. Exiting.
```

**Root cause**: A `cluster_info.json` file existed in the `config/` folder (likely a blank template
or leftover from a previous attempt) but had no `cluster_name` value. When the file *exists* but
`cluster_name` is empty, the code reaches this line in `Test-ConfigConsistency`:

```powershell
if (-not $clusterInfoName) {
    Write-ErrorLog "cluster_info.json is missing cluster_name" -Fatal   # ← crashes
}
```

This is the correct guard for the K3s path (where a populated file is required), but it is too
strict for the AKS-EE path. On AKS-EE, `cluster_info.json` is not generated at all — its absence
is expected and handled gracefully (`$script:ClusterData = $null`). But a *present-but-empty* file
breaks that logic because `$script:ClusterData` is not null; it's a parsed object with null fields.

**Suggested fix**: Treat a `cluster_info.json` with an empty `cluster_name` the same as a missing
file on the AKS-EE path (fall through to config/env var resolution). Should also print a clear
diagnostic before dying, e.g.:
```
WARNING: cluster_info.json found at <path> but cluster_name is empty.
         On the AKS-EE path this file is not needed — you can delete it or set AKSEDGE_CLUSTER_NAME.
         On the K3s path, this means the edge installer did not complete successfully.
```

**File**: `external_configuration/External-Configurator.ps1` — `Test-ConfigConsistency` function (~line 423)

**Proposed fix** — follow the standard resolution order (see Design Decision) instead of crashing. Replace:

```powershell
# BEFORE (crashes on blank cluster_info.json)
if (-not $clusterInfoName) {
    Write-ErrorLog "cluster_info.json is missing cluster_name" -Fatal
}
```

With:

```powershell
# AFTER — env var → config → prompt, never crash on a blank field
if (-not $clusterInfoName) {
    Write-WarnLog "cluster_info.json was found but cluster_name is empty."
    Write-Host "  Falling back to env var / aio_config.json for cluster name." -ForegroundColor Yellow
    Write-Host "  (On the AKS-EE path this file is not required — safe to delete.)" -ForegroundColor Gray

    # 1. Env var
    if ($env:AKSEDGE_CLUSTER_NAME) {
        $script:ClusterName = $env:AKSEDGE_CLUSTER_NAME
        Write-InfoLog "[ENV] Cluster name from AKSEDGE_CLUSTER_NAME: $script:ClusterName"
    # 2. aio_config.json value already loaded into $script:ConfigClusterName
    } elseif ($script:ConfigClusterName) {
        $script:ClusterName = $script:ConfigClusterName
        Write-InfoLog "[CONFIG] Cluster name from aio_config.json: $script:ClusterName"
    # 3. Prompt
    } else {
        Write-Warning "[INPUT] Cluster name not found in env vars or config."
        $script:ClusterName = Read-Host "Enter Cluster name"
        $env:AKSEDGE_CLUSTER_NAME = $script:ClusterName
        Write-Host "[INPUT] Saved as `$env:AKSEDGE_CLUSTER_NAME for this session." -ForegroundColor Cyan
    }
    $script:ClusterData = $null  # Treat as not loaded
    return
}
```

---

## Summary Table

| # | Script | Severity | Description |
|---|--------|----------|-------------|
| 1 | AKS-EE quickstart (external) | ~~Medium~~ **WON'T FIX** | Env vars not picked up; AIDE files always needed — external team |
| 2 | AKS-EE quickstart (external) | ~~Low~~ **WON'T FIX** | `$location` missing from run command — external team |
| 3 | README.md | Low | Malformed download command block in AKS-EE section |
| 4 | `grant_entra_id_roles.ps1`, `External-Configurator.ps1` | **High** | Env vars checked *after* prompt — users prompted unnecessarily |
| 5 | `grant_entra_id_roles.ps1`, `External-Configurator.ps1` | Medium | No logging of what was checked before prompting |
| 6 | `grant_entra_id_roles.ps1`, `External-Configurator.ps1` | Medium | User input not persisted as env var for the session |
| 7 | `External-Configurator.ps1` | **High** | Empty `cluster_info.json` causes fatal crash instead of graceful fallback |
