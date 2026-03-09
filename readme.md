# Azure IoT Operations - Quick Start

Automated deployment of Azure IoT Operations (AIO) on edge devices with industrial IoT applications.

## What You Get

- ⚡ **One-command edge setup** - Automated K3s cluster with Azure IoT Operations
- 🏭 **Industrial IoT apps** - Factory simulator, MQTT historian, data processors
- ☁️ **Cloud integration** - Dataflow pipelines to Azure (ADX, Event Hubs, Fabric) using **Managed Identity** — no secrets to manage.
- 🔧 **Production-ready** - Separation of edge and cloud configuration for security
- 💻 **Single-machine (AKS-EE)** - Run everything on one Windows laptop with session-bootstrap.ps1

> **For detailed technical information, see [README_ADVANCED.md](README_ADVANCED.md)**

## Why not use codespaces from the docs? 
The docs have a very clean "one click" deployment in the MSFT docs. It's a great first step, especially if you just want to see the tools. 
* That will live in its own environment and you won't be able to connect it to your signals or your devices. 
* This version will help you set up AIO in the actual environment where you do your IoT operations.
* This is much closer to a production-level deployment.
* This instance will last as long as you want to keep it.

As the end-goal is an IoT solution, this repo has a preference for installing on hardware over virtualization. The goal is that you can put this in your IoT environment, validate the build, and then migrate to a production version. 


# Quick Start
The goal here is to install AIO on an Ubuntu machine (like a local NUC, PC, or a VM) so that you can get working quickly on your dataflow pipelines and get data into Fabric quickly. 
* _if you are in a purely testing or validation phase you can create a quick VM using [this process](docs/quick_vm_build.md)_
* _if you are building on a Windows machine using AKS Edge Essentials, see the [Single Windows Machine (AKS-EE)](#single-windows-machine-aks-ee) section below._

> **Using AKS Edge Essentials (Windows-based edge)?**  
> Follow the [Deploy AIO on AKS Edge Essentials](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot) guide to set up your edge cluster, then **skip to step 4** (Azure Configuration from Windows Machine) below. Steps 1–3b do not apply to AKS-EE.

Once you have setup AIO via this process, you should be able to do everything that you want in the cloud without touching the Ubuntu machine again.


![Process Overview](docs/img/process_1.png)

### The process involves running four scripts:
#### On the edge machine:
1. arc_build_linux\installer.sh
2. arc_build_linux\arc_enable.ps1
#### On your Windows Machine:
3. external_configuration\grant_entra_id_roles.ps1
4. external_configuration\External-Configurator.ps1


Specific commands for them are below. 

**Note** Installing AIO can be different depending on your setup. In many cases, you have to run some scripts multiple times or in different order. The log messages in each script should tell you what to do next. 

## Prerequisites

### Hardware (Ubuntu / K3s path)
- **Hardware**: Ubuntu machine with 16GB RAM, 4 CPU cores, 50GB disk
- **Azure**: Active subscription with admin access
- **Network**: Internet connectivity (edge device and management machine)

### Windows Management Machine (required for all paths)
- **PowerShell 7+** (strongly recommended — 5.1 will produce a warning but may still work)  
  Download: <https://aka.ms/install-powershell>
- **Azure CLI ≥ 2.64.0**  
  Install: <https://aka.ms/installazurecliwindows>  
  Check version: `az --version`  
  Upgrade: `az upgrade`
- **Required CLI extensions** (install once, then update with `az extension update --name <ext>`):
  ```powershell
  az extension add --upgrade --name azure-iot-ops
  az extension add --upgrade --name connectedk8s
  ```
- **Execution Policy** — the scripts in this repo are unsigned. Run this once at the start of each PS session:
  ```powershell
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
  ```

## Installation

### 1. Get the Repository

**Option A — Download ZIP** (no Git required):  
Click the green **Code** button on this GitHub page and choose **Download ZIP**, then extract to a local working directory.

**Option B — Clone with Git**:
```bash
# Install git if not already installed
sudo apt update && sudo apt install -y git

git clone https://github.com/BillmanH/learn-iot.git
cd learn-iot
```

### 2a. Create and Complete Config File ⚠️ **DO THIS FIRST**

**Before running any installation scripts**, create and configure `aio_config.json`:

```bash
cd config
cp quikstart_config.template aio_config.json
```

Edit `aio_config.json` with your settings:
- Cluster name for your edge device
- Optional tools to install (k9s, mqtt-viewer, ssh, and powershell)

**This config file controls the edge deployment.** Review it carefully before proceeding.

### 3. Edge Setup (On Ubuntu Device)

```bash
cd arc_build_linux
bash installer.sh
```

**What it does**: Installs K3s, kubectl, Helm, and prepares the cluster for Azure IoT Operations  
**Time**: ~10-15 minutes  
**Output**: `config/cluster_info.json` (needed for next step)

> **Note**: System may restart during installation. This is normal. Rerun the script after restart to continue.

### 3b. Arc-Enable Cluster (On Ubuntu Device)

After installer.sh completes, connect the cluster to Azure Arc:

```bash
# Still on the edge device (PowerShell is installed by installer.sh)
pwsh ./arc_enable.ps1
```

**What it does**: 
- Logs into Azure (interactive device code flow)
- Creates resource group if needed
- Connects the K3s cluster to Azure Arc
- Enables required Arc features (custom-locations, OIDC, workload identity)
- Configures K3s to use the Arc OIDC issuer (required for Key Vault secret sync)

**Time**: ~5 minutes  
**Why on the edge device?**: Arc enablement requires kubectl access to the cluster, which isn't available remotely.

![k9s pre iot](docs/img/k9s-pre-iot.jpg)
After this you should see the core arc-kubernetes components on your edge device. 


> **Note**: If you need remote access via Arc proxy, see [README_ADVANCED.md](README_ADVANCED.md#azure-arc-rbac-issues) for RBAC setup.

![resources pre iot](docs/img/azure-resources-pre-iot.png)

### 4. Azure Configuration (From Windows Machine)

Transfer the `config/` folder to your Windows management machine, then:

```powershell
cd external_configuration

# Run this once at the start of your PS session (scripts are unsigned)
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# First, grant yourself the required Azure permissions
# This uses your current signed-in Azure identity by default
.\grant_entra_id_roles.ps1

# To grant permissions to a different user, use their Object ID (GUID):
# Get your Object ID: az ad signed-in-user show --query id -o tsv
# Find another user: az ad user list --filter "startswith(displayName,'username')" --query "[].{Name:displayName, OID:id}" -o table
.\grant_entra_id_roles.ps1 -AddUser 12345678-1234-1234-1234-123456789abc
```

This is separate because it may be that the person who has the ability to assign permissions is different than the person who will be building the resource.

```powershell
# Deploy Azure IoT Operations
.\External-Configurator.ps1

# On a single-node demo machine (laptop / AKS-EE), add -DemoMode to reduce broker RAM
# from ~15.8 GB (default) to ~303 MiB — NOT for production use
.\External-Configurator.ps1 -DemoMode
```

> **⚠️ IMPORTANT: You may need to run `grant_entra_id_roles.ps1` multiple times!**  
> The script grants permissions to resources that exist at the time it runs. If `External-Configurator.ps1` creates new resources (like Schema Registry) and then fails on role assignments, simply run `grant_entra_id_roles.ps1` again to grant permissions to the newly created resources, then re-run `External-Configurator.ps1`.

> **💡 MOST COMMON ISSUE: Moving to the next step before clusters are ready**  
> If you get errors, don't just re-run the script immediately. The error messages include troubleshooting steps - **read them carefully**. Common issues include:
> - Arc cluster showing "Not Connected" (check Arc agent pods on edge device)
> - Role assignment failures (run `grant_entra_id_roles.ps1` first)
> - IoT Operations deployment failing (ensure Arc is fully connected)
>
> Always verify the previous step completed successfully before moving on. Use `kubectl get pods -n azure-arc` on the edge device to confirm Arc agents are running.

**WARNING** the field `kubeconfig_base64` in cluster_info.json contains a secret. Be careful with that. 

**What it does**: Deploys AIO infrastructure (storage, Key Vault, schema registry) and IoT Operations  
**Time**: ~15-20 minutes  
**Note**: Arc enablement was already done on the edge device in step 3b

![k9s post iot](docs/img/k9s-post-iot.jpg)
![resources post iot](docs/img/azure-resources-post-iot.png)

### 5. Verify Installation

SSH into your Linux edge device and run:

```bash
# Check pods are running
kubectl get pods -n azure-iot-operations

# View MQTT messages
kubectl logs -n azure-iot-operations -l app=aio-broker-frontend --tail=20
```

## Key Documentation

### Infrastructure & Setup

- **[Config Files Guide](./config/readme.md)** - Configuration file templates and outputs
- **[Linux Build Advanced](./arc_build_linux/linux_build_steps.md)** - Advanced flags, troubleshooting, and cleanup scripts
- **`arc_build_linux/installer.sh`** - Edge device installer (local infrastructure only)
- **`external_configuration/External-Configurator.ps1`** - Remote Azure configurator (cloud resources only)
- **`external_configuration/Deploy-EdgeModules.ps1`** - Automated deployment script for edge applications

### Applications & Samples

- **[Edge MQTT Simulator](./modules/edgemqttsim/README.md)** - Comprehensive factory telemetry simulator
- **[Edge Historian](./modules/demohistorian/README.md)** - SQL-based historian with HTTP API for querying historical MQTT data
- **[Fabric Integration](./Fabric_setup/fabric-realtime-intelligence-setup.md)** - Connecting AIO to Microsoft Fabric

## What's Included

### Edge Applications (`modules/`)
- **edgemqttsim** - Factory equipment simulator (CNC, 3D printer, welding, etc.)
- **demohistorian** - SQL-based MQTT historian with HTTP API
- **sputnik** - Simple MQTT test publisher
- **hello-flask** - Basic web app for testing

### Key Directories
- **`arc_build_linux/`** - Edge device installation scripts (runs on Ubuntu)
- **`external_configuration/`** - Azure configuration scripts (runs on Windows)
- **`config/`** - Configuration files and cluster info outputs
- **`fabric_setup/`** - Microsoft Fabric Real-Time Intelligence integration
- **`operations/`** - Dataflow configurations for cloud connectivity
- **`modules/`** - Deployable edge modules and ARM templates

## Configuration

Customize edge deployment via `arc_build_linux/aio_config.json`:
- Cluster name for your edge device
- Optional tools (k9s, MQTT viewers, SSH)
- Azure AD principal for Arc proxy access

Customize Azure deployment via `config/aio_config.json`:
- Azure subscription and resource group settings
- Location and namespace configuration
- Key Vault settings for secret management
- `container_registry` — short name (e.g. `myregistry`) for the Azure Container Registry used by `Deploy-EdgeModules.ps1`; auto-generated if blank

---

## Single Windows Machine (AKS-EE)

If you are running both AKS Edge Essentials (edge) and the Azure management scripts on the **same Windows laptop**, use `session-bootstrap.ps1` to configure everything once per session — no JSON file editing required.

### Prerequisites
- PowerShell 7+ (`winget install Microsoft.PowerShell`)
- Azure CLI ≥ 2.64.0 (`winget install Microsoft.AzureCLI`)
- `azure-iot-ops` and `connectedk8s` extensions (see [Prerequisites](#prerequisites))

### Workflow

**Step 1 — Fill in your details once**

Open `external_configuration\session-bootstrap.ps1` and fill in the 6 required values at the top:
```powershell
$AZ_SUBSCRIPTION_ID    = "your-subscription-id"
$AZ_TENANT_ID          = "your-tenant-id"
$AZ_LOCATION           = "eastus2"   # or your preferred region
$AZ_RESOURCE_GROUP     = "rg-my-iot"  # created if it doesn't exist
$AKS_EDGE_CLUSTER_NAME = "my-aksee-cluster"
$CUSTOM_LOCATIONS_OID  = ""  # az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
```

**Step 2 — Run session-bootstrap.ps1** (once at the start of each PS7 session)
```powershell
cd external_configuration
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\session-bootstrap.ps1
```
This sets `$global:*` variables (for `AksEdgeQuickStartForAio.ps1`) and `$env:AZURE_*` variables (for `grant_entra_id_roles.ps1` and `External-Configurator.ps1`).

**Step 3 — Set up your AKS-EE edge cluster**

Follow the [Deploy AIO on AKS Edge Essentials](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot) guide. The `$global:*` variables set by `session-bootstrap.ps1` are picked up automatically.

**Step 4 — Grant permissions and deploy AIO**
```powershell
.\grant_entra_id_roles.ps1
.\External-Configurator.ps1 -DemoMode   # -DemoMode recommended for single-machine setups
```

> **Tip**: Run `session-bootstrap.ps1` once each time you open a new PS7 window. All other scripts pick up the values automatically — no need to re-edit `aio_config.json`.

## Next Steps

After installation:

1. **View MQTT messages**: See [README_ADVANCED.md](README_ADVANCED.md#monitoring-mqtt-traffic)
2. **Deploy applications**: See [README_ADVANCED.md](README_ADVANCED.md#deploying-edge-applications)
3. **Connect to Fabric**: See [README_ADVANCED.md](README_ADVANCED.md#fabric-integration)
4. **Troubleshooting**: See [README_ADVANCED.md](README_ADVANCED.md#troubleshooting)

## Documentation

- **[README_ADVANCED.md](README_ADVANCED.md)** - Detailed technical guide
- **[Application READMEs](modules/)** - Individual app documentation

## Support

- [Azure IoT Operations Docs](https://learn.microsoft.com/azure/iot-operations/)
- [K3s Documentation](https://docs.k3s.io/)
- [Issue Tracker](https://github.com/yourusername/learn-iot/issues)