# `azd up` Path — Design Document

## Overview

This document designs a new **one-command deployment path** for this repository using the Azure Developer CLI (`azd up`). The goal is a zero-touch experience: a developer with only the Azure CLI and `azd` installed can run a single command and get a fully configured Azure IoT Operations environment with a virtual machine acting as the edge device.

This path runs **in parallel** to the existing manual path. Nothing in the existing workflow is removed or changed.

---

## Comparison: Manual Path vs `azd up` Path

| Concern | Manual Path | `azd up` Path |
|---|---|---|
| Edge device | Physical or pre-existing edge device (on-prem or VM) | Azure VM provisioned automatically |
| K3s install | `installer.sh` run by hand on the edge device | Cloud-init / Custom Script Extension baked into provisioning |
| Arc connection | `arc_enable.ps1` run manually with PowerShell on the edge | `azd` post-provision hook |
| Azure resources | `External-Configurator.ps1` + ARM templates | Bicep templates provisioned by `azd` |
| RBAC / permissions | `grant_entra_id_roles.ps1` run separately | Bicep role assignments + post-provision hook |
| Key Vault + secret sync | Manual steps | Automated in post-provision hook |
| AIO install | `az iot ops init` + `az iot ops create` via PS script | Post-provision hook after Arc is ready |
| Time to working environment | Hours (multiple manual steps across machines) | ~30 minutes (single command) |
| Good for | Physical edge hardware, custom configurations, production | Learning, demos, development, quick experiments |

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Azure Resource Group                        │
│                                                                 │
│   ┌──────────────┐     ┌──────────────┐    ┌────────────────┐  │
│   │  Key Vault   │     │  Storage Acct│    │ Schema Registry│  │
│   └──────────────┘     └──────────────┘    └────────────────┘  │
│                                                                 │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │              Ubuntu VM ("virtual edge")                  │  │
│   │                                                          │  │
│   │   K3s cluster ──► Azure Arc ──► Azure IoT Operations     │  │
│   │   CSI Secret Store Driver (Key Vault sync)               │  │
│   │   Optional: edge modules (edgemqttsim, sputnik, etc.)    │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│   ┌──────────────┐     ┌──────────────┐                        │
│   │ Managed      │     │  VNet / NSG  │                        │
│   │ Identity     │     │  (VM network)│                        │
│   └──────────────┘     └──────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Proposed Repository Layout

A new top-level folder `azd-deploy/` will contain everything for this path. It does not interfere with existing scripts.

```
azd-deploy/
    azure.yaml              # azd project manifest
    main.bicep              # Root Bicep orchestration template
    main.parameters.json    # Parameter file (gitignored, template committed)
    main.parameters.template.json
    modules/
        network.bicep                # VNet, Subnet, NSG, Public IP
        vm.bicep                     # Ubuntu VM + System-assigned Managed Identity
        keyVault.bicep               # Key Vault (adapted from arm_templates/)
        storageAccount.bicep         # Storage (adapted from arm_templates/)
        schemaRegistry.bicep         # Schema Registry (adapted from arm_templates/)
        managedIdentity.bicep        # User-assigned identity for secret sync
        roleAssignments.bicep        # All RBAC in one place
        containerRegistry.bicep      # ACR Basic tier for edge module images
    scripts/
        cloud-init.yaml              # VM bootstrap: K3s, kubectl, Helm, CSI driver
        post-provision.ps1           # azd hook: Arc connection + AIO install (PowerShell)
        deploy-modules.ps1           # standalone: deploy/redeploy edge modules (PowerShell)
        suspend.ps1                  # deallocate VM to save cost (keeps AIO config intact)
        resume.ps1                   # reallocate VM and verify AIO is healthy
    README.md
```

---

## Phases

### Phase 1 — Design (this document) ✅

Agree on scope, architecture, file layout, open questions before writing a line of code.

---

### Phase 2 — Bicep Infrastructure Templates ✅

The existing ARM templates in `arm_templates/` will be ported to Bicep. Each ARM template maps to a Bicep module in `azd-deploy/modules/`.

**Resources to provision:**

1. **Virtual Network + NSG**
   - Single VNet with one subnet
   - NSG rules: allow SSH (22) from deployer IP, allow K8s API (6443) inbound within VNet
   - Public IP for SSH access during provisioning (can be removed post-provision)

2. **Ubuntu VM**
   - Size: `Standard_D4s_v3` (4 vCPU, 16 GB RAM) — matches installer.sh minimum
   - Image: `Ubuntu 24.04 LTS`
   - Auth: SSH public key sourced from Key Vault by default (generated during `post-provision.ps1`); overridden by `AZURE_VM_SSH_PUBLIC_KEY` if provided
   - System-assigned managed identity (for Arc and later AIO access)
   - `cloud-init.yaml` passed as `customData` to bootstrap K3s on first boot

3. **Key Vault** — adapted from `arm_templates/keyVault.json`

4. **Storage Account** — adapted from `arm_templates/storageAccount.json`

5. **Schema Registry** — adapted from `arm_templates/schemaRegistry.json`

6. **User-assigned Managed Identity** — adapted from `arm_templates/managedIdentity.json`

7. **Role Assignments** (all in one Bicep module)
   - Storage Blob Data Contributor → schema registry identity
   - Key Vault Secrets User → AIO managed identity
   - Key Vault Secrets Officer → deploying user (for seed secrets)
   - Azure Connected Machine Onboarding → VM system identity (for Kubernetes Arc)
   - AcrPull → VM system-assigned identity (for pulling module images from ACR)

8. **Azure Container Registry (ACR)** — Basic tier, used for edge module images
   - Provisioned in the same resource group
   - VM system-assigned identity is granted AcrPull so K3s can pull images without credentials

> **Arc method resolved:** AIO requires the K3s cluster to be Arc-enabled as a **Kubernetes cluster** (`az connectedk8s connect`), not just the VM as a machine (`azcmagent`). The VM is only the host. All Arc steps in `post-provision.ps1` use `az connectedk8s connect`.

---

### Phase 3 — VM Bootstrap (`cloud-init.yaml`) ✅

The cloud-init script runs on first VM boot and mirrors the core of `installer.sh`, scoped down to the minimum needed for a virtual edge:

```yaml
# cloud-init.yaml (sketch)
packages:
  - curl
  - apt-transport-https
  - jq

runcmd:
  # K3s install
  - curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.30.6+k3s1" sh -
  # Wait for K3s to be ready
  - until k3s kubectl get nodes; do sleep 5; done
  # Install Helm
  - curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  # Install CSI Secret Store driver (needed for Key Vault secret sync)
  - helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
  - helm install csi-secrets-store-provider-azure ... -n kube-system
  # Optional tools — rendered conditionally by Bicep templateSpec or passed as cloud-init variables
  # k9s: terminal-based Kubernetes UI
  # - if [ "${INSTALL_K9S}" = "true" ]; then
  #     K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
  #     curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_arm64.tar.gz" | tar -xz -C /usr/local/bin k9s
  #   fi
  # mqttui: terminal MQTT client (browse topics, publish/subscribe)
  # - if [ "${INSTALL_MQTTUI}" = "true" ]; then
  #     MQTTUI_VERSION=$(curl -s https://api.github.com/repos/EdJoPaTo/mqttui/releases/latest | jq -r .tag_name)
  #     curl -sL "https://github.com/EdJoPaTo/mqttui/releases/download/${MQTTUI_VERSION}/mqttui-${MQTTUI_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C /usr/local/bin mqttui
  #   fi
  # Signal readiness (write a file that post-provision.sh can poll for)
  - touch /tmp/k3s-ready
```

> **Note on optional tools:** The three boolean parameters control what gets installed on the VM and how the NSG is configured:
> - `INSTALL_K9S` — [k9s](https://k9scli.io/) gives a live terminal dashboard for the K3s cluster. Useful for exploring AIO pods interactively.
> - `INSTALL_MQTTUI` — [mqttui](https://github.com/EdJoPaTo/mqttui) is a terminal MQTT browser. Useful for verifying the AIO broker and watching messages from edge modules.
> - `OPEN_SSH_PORT` — when `true` (default), NSG keeps port 22 open so you can SSH into the VM. Set to `false` if you want a locked-down VM and will use `az vm run-command` or Azure Bastion instead.

**VM communication strategy:** The post-provision hook uses **`az vm run-command invoke`** (no SSH required) for all steps up to and including Arc connection. This means SSH never needs to be open and the user's Entra ID credentials are used for auth throughout. Once the cluster is Arc-connected, all subsequent Kubernetes operations switch to **`az connectedk8s proxy`**, which tunnels `kubectl` through the Arc control plane without any direct network access to the VM.

```
Phase A — before Arc (uses az vm run-command invoke):
  - Poll for /tmp/k3s-ready
  - Run az connectedk8s connect on the VM
  - Run helm upgrade azure-arc (custom-locations workaround)
  - Run az connectedk8s update --enable-workload-identity (workload identity workaround)

Phase B — after Arc (uses az connectedk8s proxy):
  - All kubectl commands (pod checks, rollouts, etc.)
  - az iot ops init / az iot ops create (these call the ARM/Arc APIs directly, no proxy needed)
  - az iot ops secretsync enable
  - Module deployment: kubectl apply -f deployment.yaml via proxy
```

> **Why not SSH?** `az vm run-command invoke` authenticates with Entra ID (same credentials used for `azd`), works even when `OPEN_SSH_PORT=false`, and avoids storing or distributing SSH keys in the automation scripts. The trade-off is that run-command output is buffered (not streaming), so long-running steps like the K3s readiness poll need to be written as retry loops inside the invoked script rather than real-time output.

---

### Phase 4 — Post-Provision Hook (`post-provision.ps1`) ✅

`azd` supports lifecycle hooks. The `postprovision` hook runs after all Bicep resources are deployed.

This script does the work that currently requires `arc_enable.ps1` and `External-Configurator.ps1`:

```
Step 1: Wait for VM bootstrap to complete
  - az vm run-command invoke: poll until /tmp/k3s-ready exists (retry loop, 2-min intervals, 20-min timeout)

Step 2: Arc-enable the K3s cluster
  - az vm run-command invoke: az connectedk8s connect --name <cluster> --resource-group <rg>
  - az connectedk8s enable-features --features cluster-connect custom-locations --custom-locations-oid <oid>
  - az vm run-command invoke: helm upgrade azure-arc (custom-locations helm gap workaround)
  - az connectedk8s update --enable-workload-identity (workload identity webhook workaround)

  --- Arc is now connected; switch to az connectedk8s proxy for all kubectl ops ---

Step 3: Enable secret sync (CSI + AIO secret sync)
  - az iot ops secretsync enable --name <instance> ...  [ARM API call, no proxy needed]

Step 4: Deploy AIO
  - az iot ops init --cluster <name> --resource-group <rg>  [ARM API call]
  - az iot ops create --cluster <name> --resource-group <rg> ...  [ARM API call]

Step 5: Grant deploying-user access
  - Grant Key Vault Secrets Officer to current user  [ARM API call]
  - Grant IoT Ops Data Owner / Schema Registry Contributor to current user  [ARM API call]

Step 6: Deploy optional edge modules (if any DEPLOY_MODULE_* parameter is true)
  - Delegates to deploy-modules.ps1, which uses az connectedk8s proxy for kubectl apply

Step 7: Verify
  - az connectedk8s proxy: kubectl get pods -n azure-iot-operations
  - az connectedk8s proxy: kubectl get pods -n default (confirms module pods if any were deployed)
  - Report success or failure
```

---

### Phase 4a — Edge Module Deployment & Redeployment (`deploy-modules.ps1`)

This is a **standalone script** that can be called:
- Automatically at the end of `post-provision.ps1` when any `DEPLOY_MODULE_*` parameter is `true`
- Manually at any later time to deploy, update, or redeploy individual modules without re-running `azd up`

```
Usage:
  # Deploy/redeploy all enabled modules (reads DEPLOY_MODULE_* from azd env)
  .\azd-deploy\scripts\deploy-modules.ps1

  # Deploy a specific module explicitly (overrides env flags)
  .\azd-deploy\scripts\deploy-modules.ps1 -Module edgemqttsim
  .\azd-deploy\scripts\deploy-modules.ps1 -Module sputnik
  .\azd-deploy\scripts\deploy-modules.ps1 -Module hello-flask
  .\azd-deploy\scripts\deploy-modules.ps1 -Module demohistorian

  # Deploy multiple specific modules
  .\azd-deploy\scripts\deploy-modules.ps1 -Module edgemqttsim,sputnik

  # Redeploy (pull latest image + restart pods) without changing config
  .\azd-deploy\scripts\deploy-modules.ps1 -Module edgemqttsim -Redeploy
```

**What the script does for each selected module:**
1. Reads `azd env get-values` to get resource group, cluster name, container registry (if any)
2. Optionally builds and pushes the container image (if `--build` flag is passed)
3. Uses `az connectedk8s proxy` to run `kubectl apply -f deployment.yaml` (no SSH needed)
4. For `--redeploy`: runs `kubectl rollout restart deployment/<name>` via the same proxy
5. Tails pod logs briefly via proxy to confirm startup

**Redeploy workflow (after initial `azd up`):**
```powershell
# Edit module code locally, then:
.\azd-deploy\scripts\deploy-modules.ps1 -Module edgemqttsim -Build -Redeploy
```

This mirrors what `Deploy-EdgeModules.ps1` does in the manual path, but is self-contained for the `azd up` path and reads its config from `azd env` rather than `aio_config.json`.

**Open question:** How does `post-provision.ps1` SSH into the VM?
- ~~Option A: Use the SSH key provided at deploy time (simplest)~~
- ~~Option B: Use `az vm run-command invoke` (no SSH needed, but slower and output is limited)~~ ✅ **Selected** — authenticates with Entra ID, works when `OPEN_SSH_PORT=false`, used for pre-Arc steps
- ~~Option C: Use `az connectedk8s proxy` for kubectl access after Arc is connected (good for K8s ops but not for the initial Arc connection itself)~~ ✅ **Selected** — used for all post-Arc kubectl operations

**Resolved:** `az vm run-command invoke` for pre-Arc steps; `az connectedk8s proxy` for all post-Arc kubectl operations. SSH is never required.

---

### Phase 5 — `azure.yaml` Manifest ✅

```yaml
# azure.yaml
name: learn-iothub
metadata:
  template: learn-iothub@0.0.1

infra:
  provider: bicep
  path: azd-deploy
  module: main

hooks:
  postprovision:
    shell: pwsh
    run: azd-deploy/scripts/post-provision.ps1
    interactive: true
    continueOnError: false
```

**Parameters exposed to users via `azd env`:**

| Parameter | Description | Default |
|---|---|---|
| `AZURE_VM_ADMIN_USERNAME` | SSH username for the VM | `aiouser` |
| `AZURE_VM_SSH_PUBLIC_KEY` | SSH public key to use instead of generating one via Key Vault | *(optional — Key Vault-generated by default)* |
| `AZURE_VM_SIZE` | VM SKU | `Standard_D4s_v3` |
| `AZURE_LOCATION` | Azure region | `westus2` |
| `AZURE_RESOURCE_GROUP` | Resource group name | (generated from env name) |
| `AIO_CLUSTER_NAME` | Arc cluster name | (generated from env name) |
| `AIO_KEY_VAULT_NAME` | Key Vault name | (generated from env name) |
| `AZURE_CONTAINER_REGISTRY_NAME` | ACR name for edge module images | (generated from env name) |
| `INSTALL_K9S` | Install k9s (terminal K8s UI) on the VM | `false` |
| `INSTALL_MQTTUI` | Install mqttui (terminal MQTT client) on the VM | `false` |
| `OPEN_SSH_PORT` | Keep SSH port 22 open in NSG after provisioning | `true` |
| `DEPLOY_MODULE_EDGEMQTTSIM` | Deploy the edgemqttsim industrial IoT simulator module | `false` |
| `DEPLOY_MODULE_SPUTNIK` | Deploy the sputnik MQTT test publisher module | `false` |
| `DEPLOY_MODULE_HELLO_FLASK` | Deploy the hello-flask REST API example module | `false` |
| `DEPLOY_MODULE_DEMOHISTORIAN` | Deploy the demohistorian module | `false` |

---

### Phase 6 — Documentation & Testing ✅ (docs done; testing pending)

- `azd-deploy/README.md` — step-by-step user guide for the `azd up` path
- Update root `readme.md` to show both paths side by side
- Test matrix:
  - Fresh `azd up` from zero
  - `azd up` idempotency (run twice, no errors)
  - `azd down` cleanup (full teardown)
  - Verify AIO broker is reachable
  - Verify edgemqttsim module can be deployed on top with `Deploy-EdgeModules.ps1`

---

## Open Questions / Design Decisions

These need to be resolved before implementation begins:

### Q1: Bicep vs reuse existing ARM templates? ✅ Resolved
- ✅ **Option A selected:** Port existing `arm_templates/*.json` to Bicep. Cleaner, native azd support, better modularity.
- ~~Option B: Keep ARM JSON and use them from Bicep via `module` with `templateType: 'ARM'`. Less work but mixes formats.~~

### Q2: How should the post-provision hook run? ✅ Resolved
- ~~Option A: Bash script (requires WSL or macOS/Linux on the developer machine)~~
- ✅ **Option B selected:** PowerShell script (works natively on Windows, aligns with existing scripts)
- ~~Option C: Both — azd supports platform-specific hooks (`windows` / `posix`)~~

### Q3: SSH key management ✅ Resolved
- ✅ **Default:** `post-provision.ps1` generates an RSA key pair, stores the private key as a Key Vault secret (`aio-vm-ssh-private-key`) and passes the public key to the VM at provision time. The user never needs to manage a key file.
- **Optional override:** If `AZURE_VM_SSH_PUBLIC_KEY` is set in `azd env`, that public key is used instead and no key is generated or stored. The user is responsible for holding the matching private key.
- The `OPEN_SSH_PORT` parameter still controls whether the NSG allows inbound SSH — the key management choice is independent of whether the port is open.

### Q4: Public IP vs Bastion ✅ Resolved
- ✅ **Public IP + NSG selected.** A public IP with a tight NSG is provisioned for this learning repo. SSH access is optional (controlled by `OPEN_SSH_PORT`); all automation uses `az vm run-command` and `az connectedk8s proxy` and never requires the port to be open.
- ~~Azure Bastion (~$140/mo, no public IP, more secure)~~ — noted as a production alternative in `azd-deploy/README.md`.

### Q5: VM deallocation after AIO install? ✅ Resolved
- `azd down` deletes everything cleanly.
- ✅ **A `suspend.ps1` / `resume.ps1` script pair will be provided** to deallocate and reallocate the VM without tearing down the resource group. This stops compute billing while preserving the AIO configuration and all other resources.
  - `suspend.ps1` — runs `az vm deallocate`, confirms deallocation
  - `resume.ps1` — runs `az vm start`, waits for K3s to be ready via `az vm run-command`, verifies AIO pods are healthy via `az connectedk8s proxy`

### Q6: Scope of edge modules in this path ✅ Resolved
- Module deployment is **optional and configurable** via `DEPLOY_MODULE_*` parameters.
- A standalone `deploy-modules.ps1` script handles both initial deployment and subsequent redeployment/updates.
- The four modules supported: `edgemqttsim`, `sputnik`, `hello-flask`, `demohistorian`.
- Build + push to container registry is opt-in (`-Build` flag) to support iterative development.
- ✅ **ACR selected:** `azd up` provisions an ACR Basic tier (~$5/mo) in the resource group. The VM system-assigned identity is granted `AcrPull` so K3s can pull images without credentials. Module images are built and pushed to this ACR.

---

## Implementation Order (once design is agreed)

```
[x] 1. Create azd-deploy/ folder structure
[x] 2. Write main.bicep + network/vm/kv/storage/schema/acr/rbac Bicep modules   ← Phase 2 ✅
[x] 3. Write azure.yaml manifest                                                  ← Phase 2 ✅
[x] 4. Write pre-provision.ps1 (SSH key generation + defaults)                   ← Phase 2 ✅
[x] 5. Write post-provision.ps1 (Arc + AIO + optional modules)                   ← Phase 2 ✅
[x] 6. Write deploy-modules.ps1 (standalone module deploy/redeploy)              ← Phase 2 ✅
[x] 7. Write suspend.ps1 + resume.ps1 (VM cost-saving scripts)                   ← Phase 2 ✅
[x] 8. Write azd-deploy/README.md (includes suspend/resume workflow, Bastion note)
[x] 9. Update root readme.md with path comparison
[x] 10. End-to-end test (platform only)
[ ] 11. End-to-end test (platform + all modules)
[ ] 12. Test standalone module redeploy after initial azd up
[ ] 13. Test suspend + resume cycle
```

---

## Notes on Known Issues (already documented in copilot-instructions.md)

The post-provision script must incorporate the existing known workarounds:

1. **Arc custom-locations helm gap** — `az connectedk8s enable-features` alone is not enough; must run `helm upgrade azure-arc` to actually enable the feature in the cluster.
2. **Workload identity webhook gap** — must run `az connectedk8s update --enable-workload-identity` after connecting to actually deploy the webhook pods.
3. **CSI Secret Store** — must be installed before `az iot ops secretsync enable`.
4. **SASL/SAS for Fabric endpoints** — still required even in the azd path; the post-provision hook seeds the placeholder secret in Key Vault.
5. **Device Registry dual CRD system** (AIO v1.2+) — use `assets.namespaces.deviceregistry.microsoft.com` for portal-created assets.
