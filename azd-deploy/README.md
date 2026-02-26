# `azd up` Path — Azure IoT Operations on a Virtual Edge Device

This folder contains everything needed to deploy a **complete Azure IoT Operations (AIO) environment with a single command** using the Azure Developer CLI (`azd`).

A Linux VM is provisioned automatically, K3s is bootstrapped via cloud-init, the cluster is Arc-enabled, and AIO is installed — all without touching a physical edge device.

See the [root README](../readme.md) for the manual deployment path (physical/pre-existing edge devices).

---

## How It Compares to the Manual Path

| Concern | Manual Path | `azd up` Path |
|---|---|---|
| Edge device | Physical or pre-existing Ubuntu machine | Azure VM provisioned automatically |
| K3s install | `installer.sh` run by hand on the device | Cloud-init baked into VM provisioning |
| Arc connection | `arc_enable.ps1` run manually on the device | Post-provision hook |
| Azure resources | ARM templates + `External-Configurator.ps1` | Bicep templates (`main.bicep`) |
| RBAC / permissions | `grant_entra_id_roles.ps1` run separately | Bicep role assignments + hook |
| Key Vault + secret sync | Manual steps | Automated in post-provision hook |
| AIO install | `az iot ops init` + `az iot ops create` | Post-provision hook |
| Time to working environment | Hours (multiple manual steps) | ~30 minutes (single command) |
| Best for | Physical hardware, custom configs, production | Learning, demos, development |

---

## Prerequisites

| Tool | Install |
|---|---|
| Azure CLI (`az`) | [aka.ms/installazurecli](https://aka.ms/installazurecli) |
| Azure Developer CLI (`azd`) | [aka.ms/azd-install](https://aka.ms/azd-install) |
| PowerShell 7+ (`pwsh`) | [aka.ms/install-powershell](https://aka.ms/install-powershell) |
| Docker Desktop (optional) | Only needed to build and push module images |

**Azure permissions required:**
- Contributor on the target subscription (to create a resource group and resources)
- User Access Administrator on the target subscription (to assign RBAC roles)

**Log in before running:**
```powershell
az login
azd auth login
```

---

## Quick Start

### 1. Copy and fill in the config file

```powershell
cd azd-deploy
cp config.template.yaml config.yaml
```

Open `config.yaml` and set at minimum:

```yaml
subscription_id: "your-subscription-id-here"   # az account show --query id -o tsv
resource_group: "rg-aio-dev"                   # created if it does not exist
```

Everything else has safe defaults. See the [Parameter Reference](#parameter-reference) below.

### 2. Run `azd up`

```powershell
# From the azd-deploy/ directory:
azd up
```

`azd` will prompt for an environment name (short alphanumeric, e.g. `aio-dev`). This name is used to generate unique resource names.

**What happens:**
1. `pre-provision.ps1` reads `config.yaml`, generates an SSH key pair, and stores your settings in the azd environment
2. Bicep provisions the VM, Key Vault, Storage, Schema Registry, ACR, VNet, and role assignments (~5 min)
3. `post-provision.ps1` runs a 12-step sequence:
   - Waits for cloud-init to finish K3s bootstrap on the VM
   - Connects the K3s cluster to Azure Arc (with OIDC issuer + workload identity)
   - Reconfigures K3s with the Arc-issued OIDC URL (required for Key Vault secret sync)
   - Enables custom-locations and workload identity webhook
   - Deploys Azure IoT Operations
   - Enables Key Vault secret sync
   - Seeds placeholder secrets
   - Deploys any enabled edge modules

**Total time: ~25–35 minutes** (most of it is AIO installation, which is slow regardless of path).

### 3. Verify

```powershell
# Check AIO pods via Arc proxy (no SSH needed):
az connectedk8s proxy --name <cluster-name> --resource-group <rg>
# In the proxied session:
kubectl get pods -n azure-iot-operations
```

The cluster name and resource group are printed at the end of `azd up` and can be retrieved any time:

```powershell
azd env get-values
```

---

## Parameter Reference

All parameters can be set in `config.yaml` or overridden per-run with `azd env set KEY value`.

| Parameter | config.yaml key | Default | Description |
|---|---|---|---|
| Subscription ID | `subscription_id` | *(required)* | Azure subscription to deploy into |
| Location | `location` | `eastus` | Azure region for all resources |
| Resource Group | `resource_group` | `rg-<env-name>` | Created if it does not exist |
| VM Size | `vm_size` | `Standard_D4s_v3` | 4 vCPU / 16 GB minimum for AIO |
| VM Admin Username | `vm_admin_username` | `aiouser` | Linux admin user on the VM |
| SSH Port Open | `open_ssh_port` | `true` | Keep port 22 open in the NSG |
| Install k9s | `install_k9s` | `false` | Terminal Kubernetes dashboard on VM |
| Install mqttui | `install_mqttui` | `false` | Terminal MQTT client on VM |
| Deploy edgemqttsim | `deploy_module_edgemqttsim` | `false` | Industrial IoT simulator module |
| Deploy sputnik | `deploy_module_sputnik` | `false` | Simple MQTT test publisher |
| Deploy hello-flask | `deploy_module_hello_flask` | `false` | REST API example module |
| Deploy demohistorian | `deploy_module_demohistorian` | `false` | SQL historian module |

**Override example:**
```powershell
azd env set AZURE_VM_SIZE Standard_D8s_v3
azd up
```

> **Note:** `config.yaml` is gitignored so your subscription ID and resource group name are never committed. `config.template.yaml` is the committed version with blank/default values.

---

## Accessing the VM

### Via Arc proxy (recommended — no SSH needed)

```powershell
# From azd-deploy/ using the azd env values:
$env = azd env get-values | ConvertFrom-StringData
az connectedk8s proxy --name $env.AIO_CLUSTER_NAME --resource-group $env.AZURE_RESOURCE_GROUP
```

While the proxy is running, `kubectl` in that terminal points to the edge K3s cluster:

```powershell
kubectl get pods -n azure-iot-operations
kubectl get pods -n default
kubectl logs -n azure-iot-operations -l app=aio-broker-frontend --tail=20
```

### Via SSH (if `open_ssh_port: true`)

The SSH private key is stored in Key Vault as `aio-vm-ssh-private-key`. Retrieve it:

```powershell
$env = azd env get-values | ConvertFrom-StringData
$privateKey = az keyvault secret show `
    --vault-name $env.AIO_KEY_VAULT_NAME `
    --name aio-vm-ssh-private-key `
    --query value -o tsv
$privateKey | Out-File -FilePath "$env:TEMP\aio-vm.pem" -Encoding ascii
icacls "$env:TEMP\aio-vm.pem" /inheritance:r /grant:r "${env:USERNAME}:R"

$vmIp = $env.AZURE_VM_PUBLIC_IP
ssh -i "$env:TEMP\aio-vm.pem" aiouser@$vmIp
```

---

## Deploying Edge Modules

### During `azd up`

Set `deploy_module_*: true` in `config.yaml` before running `azd up`. Docker must be running to build images.

### After initial setup

```powershell
# From azd-deploy/:

# Deploy (or redeploy) the industrial IoT simulator:
pwsh scripts/deploy-modules.ps1 -OnlyModule edgemqttsim

# Deploy multiple modules:
pwsh scripts/deploy-modules.ps1 -OnlyModule edgemqttsim
pwsh scripts/deploy-modules.ps1 -OnlyModule sputnik

# Enable a module for future `azd up` runs:
azd env set DEPLOY_MODULE_EDGEMQTTSIM true
```

---

## Suspend and Resume (Save on VM Costs)

The VM costs ~$140–200/month running 24/7 (`Standard_D4s_v3`). When you are not actively using the environment, suspend the VM to stop compute billing. All other resources (Key Vault, Storage, ACR, Arc registration, AIO configuration) remain intact.

### Suspend (deallocate VM)

```powershell
# From azd-deploy/:
pwsh scripts/suspend.ps1
```

This deallocates the VM and stops compute charges. The Arc cluster will show as **Offline** in the Azure portal until resumed.

### Resume

```powershell
# From azd-deploy/:
pwsh scripts/resume.ps1
```

K3s and AIO are already installed — cloud-init does not re-run. Arc connectivity re-establishes automatically within 2–5 minutes after boot.

> **Note:** The VM's public IP address may change after deallocation if not using a static IP. `resume.ps1` prints the new IP. Use `az connectedk8s proxy` instead of SSH to avoid the IP dependency.

---

## Tearing Down

To delete all provisioned resources:

```powershell
# From azd-deploy/:
azd down
```

This deletes the resource group and all resources inside it. If the resource group was created by `azd`, it will be removed entirely. If you provided a pre-existing resource group, the resources are deleted but the group itself remains.

> **Warning:** `azd down` is irreversible. Arc cluster registration, AIO configuration, Key Vault secrets, and all data are permanently deleted.

---

## Using Azure Bastion Instead of a Public IP (Production)

For a production or locked-down environment, you may want to remove the public IP entirely and access the VM through Azure Bastion.

- **Cost:** Azure Bastion Developer tier is free; Standard tier is ~$140/month.
- **Access:** Browser-based SSH via the Azure portal — no local SSH client or open port required.
- **Automation:** All `azd` hooks use `az vm run-command` and `az connectedk8s proxy` and do not need SSH or a public IP, so the `azd up` workflow works unchanged with `open_ssh_port: false`.

To skip the public IP:
```yaml
# config.yaml
open_ssh_port: false
```

Then set up Bastion manually after provisioning via the Azure portal (VM → Connect → Bastion).

---

## Troubleshooting

### `azd up` fails at "Waiting for K3s to be ready"

Cloud-init can take 5–10 minutes on first boot. The post-provision hook polls for 20 minutes before giving up. If it times out:

```powershell
# Check cloud-init status:
$env = azd env get-values | ConvertFrom-StringData
az vm run-command invoke `
    --resource-group $env.AZURE_RESOURCE_GROUP `
    --name $env.AZURE_VM_NAME `
    --command-id RunShellScript `
    --scripts "cat /var/log/cloud-init-output.log | tail -50"
```

### Arc connect fails with "already exists" error

The K3s cluster may have been partially registered. The script performs an idempotency check — if the cluster already exists in Azure it skips the connect step. If the state is inconsistent:

```powershell
az connectedk8s delete --name <cluster-name> --resource-group <rg> -y
# Then re-run the Arc connect on the VM:
az vm run-command invoke ... --scripts "az connectedk8s connect ..."
```

### Secret sync fails with `AADSTS700211`

This means K3s is still signing tokens with the default issuer (`https://kubernetes.default.svc.cluster.local`) instead of the Arc-issued OIDC URL. Post-provision Step 3 handles this automatically — if it failed, check the run-command output:

```powershell
az vm run-command invoke `
    --resource-group $env.AZURE_RESOURCE_GROUP `
    --name $env.AZURE_VM_NAME `
    --command-id RunShellScript `
    --scripts "cat /etc/rancher/k3s/config.yaml"
```

The file should contain `kube-apiserver-arg` with a `service-account-issuer` pointing to the Arc OIDC URL.

### `az connectedk8s proxy` fails with permission errors

Your Entra ID account needs the **Azure Arc-enabled Kubernetes Cluster User** role on the connected cluster. Run `grant_entra_id_roles.ps1` from `external_configuration/` or assign the role manually in the Azure portal.

### Custom-locations not working after Arc connect

The custom-locations feature requires both an ARM registration and a Helm chart update. Post-provision Step 4 runs `az connectedk8s enable-features` on the VM (which updates both). If it was skipped:

```powershell
# Run on the VM:
az connectedk8s enable-features `
    --name <cluster-name> `
    --resource-group <rg> `
    --features cluster-connect custom-locations `
    --custom-locations-oid <oid>
```

### AIO pods stuck in `Pending` or `CrashLoopBackOff`

```powershell
# Via Arc proxy:
az connectedk8s proxy --name <cluster-name> --resource-group <rg>
kubectl describe pods -n azure-iot-operations | grep -A10 Events
kubectl get events -n azure-iot-operations --sort-by='.lastTimestamp'
```

Common causes: insufficient VM memory (upgrade to `Standard_D8s_v3`), Arc extension installation still in progress (wait 5 minutes and re-check).

---

## What Gets Deployed

| Resource | Name Pattern | Notes |
|---|---|---|
| Resource Group | Provided in `config.yaml` | Created if missing |
| Virtual Network | `vnet-<unique>` | Single subnet, NSG with optional SSH rule |
| Ubuntu VM | `vm-<env-name>` | K3s + Arc + AIO pre-installed |
| Key Vault | `kv-<unique>` | SSH key, AIO secrets, Fabric SAS placeholder |
| Storage Account | `st<unique>` | Schema Registry backing store |
| Schema Registry | `sr-<env-name>` | AIO schema storage |
| Managed Identity | `id-<env-name>` | Used by AIO for secret sync |
| Container Registry | `acr<unique>` | Basic tier; edge module images |
| Arc Cluster | `<env-name>-cluster` | K3s cluster registered in Azure Arc |
| AIO Instance | `aio-<env-name>` | Azure IoT Operations |
| Device Registry NS | `default` namespace | Required for AIO v1.2+ asset management |

---

## File Reference

```
azd-deploy/
    azure.yaml                  # azd project manifest
    main.bicep                  # Root Bicep orchestration
    config.template.yaml        # Config template — copy to config.yaml and fill in
    config.yaml                 # Your config (gitignored)
    modules/
        network.bicep           # VNet, Subnet, NSG, Public IP
        vm.bicep                # Ubuntu VM + cloud-init (K3s bootstrap)
        keyVault.bicep          # Key Vault
        storageAccount.bicep    # Storage Account
        schemaRegistry.bicep    # Schema Registry
        managedIdentity.bicep   # User-assigned Managed Identity
        roleAssignments.bicep   # All RBAC assignments
        containerRegistry.bicep # ACR Basic tier
        deviceRegistryNamespace.bicep  # Device Registry namespace (AIO v1.2+)
    scripts/
        pre-provision.ps1       # SSH key generation, config.yaml → azd env
        post-provision.ps1      # Arc connect + AIO install (12-step flow)
        deploy-modules.ps1      # Build/push/deploy edge modules
        suspend.ps1             # Deallocate VM (stop compute billing)
        resume.ps1              # Start suspended VM
```
