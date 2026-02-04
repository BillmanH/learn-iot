# An example run. 

Installing AIO is a lot of different components. Here I'm providing a 'narrative version' as I go through the process end to end. _Your environment is different so this will be different for you_, but I think this will give you an idea of what it will be like. 

## Starting with a clean machine. 
I have an Ubuntu Server machine. Brand new.

I clone the repo.
```bash
# Install git if not already installed
sudo apt update && sudo apt install -y git

git clone https://github.com/BillmanH/learn-iot.git
cd learn-iot
```

I run the installer.
```bash
cd arc_build_linux
bash installer.sh
```

It says success, but I got this:
```
[INFO]  systemd: Starting k3s
[2026-02-04 18:20:46] Waiting for K3s to be ready...
[2026-02-04 18:20:46] ✓ K3s is ready

[2026-02-04 18:20:47] ERROR: K3s node is not in Ready state

╔══════════════════════════════════════════════════════════════════╗
║  K3s is installed but the node isn't Ready yet.                  ║
║                                                                  ║
║  ⚡ IF K3S WAS JUST INSTALLED: This is EXPECTED behavior!        ║
║     K3s needs 2-5 minutes to download images and initialize.    ║
║     Just wait and check again - no action needed.               ║
╚══════════════════════════════════════════════════════════════════╝

Wait 2-5 minutes, then check if the node is Ready:
```

I know that the kubernetes instance was just installed. But it's not ready yet. It has to do internal Kubernetes things. So I go get a coffee, do some emails, chat with people, etc. 

Then I come back and I run it again:
```bash
bash installer.sh
```

It ran again, with more green lights:
```
[2026-02-04 18:27:18] Waiting for Azure Key Vault provider to be ready...
pod/azure-csi-provider-csi-secrets-store-provider-azure-5h447 condition met
[2026-02-04 18:27:23] Verifying CSI Secret Store installation...
[2026-02-04 18:27:24] ✓ ✓ CSI driver 'secrets-store.csi.k8s.io' is installed
[2026-02-04 18:27:24] ✓ ✓ Found 1 CSI Secret Store driver pod(s)
[2026-02-04 18:27:24] ✓ ✓ Found 1 Azure Key Vault provider pod(s)
[2026-02-04 18:27:24] ✓ CSI Secret Store driver and Azure Key Vault provider installed
[2026-02-04 18:27:24] INFO: Secret management is now enabled for Azure IoT Operations dataflows
[2026-02-04 18:27:24] Applying optional RBAC binding for principal: 1dba5699-bdd4-44ea-b987-46bc645e61b1
[2026-02-04 18:27:24] ✓ Applied cluster-admin ClusterRoleBinding for: 1dba5699-bdd4-44ea-b987-46bc645e61b1
[2026-02-04 18:27:24] Configuring system settings for Azure IoT Operations...
[2026-02-04 18:27:24] ✓ System settings configured
[2026-02-04 18:27:24] Verifying local K3s cluster health...
[2026-02-04 18:27:24] ✓ Cluster node is Ready
[2026-02-04 18:27:24] Checking system pods...
NAME                                                        READY   STATUS    RESTARTS   AGE
azure-csi-provider-csi-secrets-store-provider-azure-5h447   1/1     Running   0          6s
coredns-7f496c8d7d-jwq7h                                    1/1     Running   0          6m31s
csi-secrets-store-driver-secrets-store-csi-driver-zdnc5     3/3     Running   0          13s
local-path-provisioner-578895bd58-sqcb6                     1/1     Running   0          6m31s
metrics-server-7b9c9c4b9c-dgq29                             1/1     Running   0          6m31s
[2026-02-04 18:27:24] ✓ All system pods are running
[2026-02-04 18:27:24] ✓ Local cluster verification completed
[2026-02-04 18:27:24] Generating cluster information for external configurator...
[2026-02-04 18:27:25] ✓ Cluster information saved to: /home/azureuser/learn-iot/arc_build_linux/../config/cluster_info.json

============================================================================
Edge Device Installation Completed Successfully!
============================================================================

Configuration mode: QUICKSTART

Your edge device is now ready with:
  ✓ K3s Kubernetes cluster: bel-aio-work-cluster
  ✓ kubectl and Helm configured
  ✓ CSI Secret Store driver (Azure Key Vault integration)
  ✓ Optional tools: k9s mosquitto-clients ssh

Next Steps:
```

I follow the next steps as instructed. 

```
2. Connect this cluster to Azure Arc (run on THIS machine):
   pwsh ./arc_enable.ps1
```

It takes a long time:
```
[2026-02-04 18:29:26] INFO: Connecting with custom-locations, OIDC issuer, and workload identity enabled...
[2026-02-04 18:29:26] INFO: Including CustomLocationsOid in connection
WARNING: The features 'cluster-connect' and 'custom-locations' cannot be enabled for a private link enabled connected cluster.
WARNING: Helm version 3.6.3 is required. Learn more at https://aka.ms/arc/k8s/onboarding-helm-install
In progress [Checking operation  status                                   ]
```

I do some other things and come back to it later. 
```
[2026-02-04 18:35:19] SUCCESS: Cluster is connected to Azure Arc!

============================================================================
Arc Enablement Completed!
============================================================================

Your cluster 'bel-aio-work-cluster' is now connected to Azure Arc.
Custom-locations feature has been enabled via helm.
```

