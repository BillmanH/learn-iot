// ============================================================================
// VM module: Ubuntu edge VM with system-assigned identity + cloud-init bootstrap
// ============================================================================

param location string
param clusterName string
param adminUsername string = 'aiouser'
@secure()
param sshPublicKey string
param vmSize string = 'Standard_D4s_v3'
param subnetId string
param publicIpId string
param nsgId string
param installK9s bool = false
param installMqttui bool = false
param tags object = {}

var vmName = '${clusterName}-vm'
var nicName = '${clusterName}-nic'
var osDiskName = '${clusterName}-osdisk'

// ---------------------------------------------------------------------------
// cloud-init content — constructed in Bicep so optional tools are conditional
// ---------------------------------------------------------------------------

var cloudInitBase = '''
#cloud-config
packages:
  - curl
  - apt-transport-https
  - jq
  - unzip
  - git

runcmd:
  # -----------------------------------------------------------------------
  # Sysctl settings required by Azure IoT Operations
  # (mirrors configure_system_settings in installer.sh)
  # -----------------------------------------------------------------------
  - [ bash, -c, "cat > /etc/sysctl.d/99-azure-iot-operations.conf << 'EOF'\nnet.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nfs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 524288\nvm.max_map_count = 262144\nEOF" ]
  - [ bash, -c, "sysctl --system" ]

  # -----------------------------------------------------------------------
  # Install K3s — traefik disabled (not needed by AIO, saves resources)
  # -----------------------------------------------------------------------
  - [ bash, -c, "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.30.6+k3s1' sh -s - --disable traefik --write-kubeconfig-mode 644" ]

  # Wait for K3s node to be Ready
  - [ bash, -c, "until k3s kubectl get nodes | grep -q ' Ready '; do echo 'Waiting for K3s node...'; sleep 10; done" ]

  # Copy kubeconfig for the admin user (needed when az vm run-command runs as that user)
  - [ bash, -c, "mkdir -p /root/.kube && cp /etc/rancher/k3s/k3s.yaml /root/.kube/config" ]

  # -----------------------------------------------------------------------
  # Install Helm
  # -----------------------------------------------------------------------
  - [ bash, -c, "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ]

  # -----------------------------------------------------------------------
  # Install CSI Secrets Store driver + Azure Key Vault provider
  # Release names match installer.sh: csi-secrets-store-driver / azure-csi-provider
  # -----------------------------------------------------------------------
  - [ bash, -c, "helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts" ]
  - [ bash, -c, "helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts" ]
  - [ bash, -c, "helm repo update" ]
  - [ bash, -c, "helm install csi-secrets-store-driver secrets-store-csi-driver/secrets-store-csi-driver --namespace kube-system --set syncSecret.enabled=true --set enableSecretRotation=true" ]
  - [ bash, -c, "kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=secrets-store-csi-driver -n kube-system --timeout=120s" ]
  - [ bash, -c, "helm install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace kube-system --set secrets-store-csi-driver.install=false" ]
  - [ bash, -c, "kubectl wait --for=condition=ready pod -l app=csi-secrets-store-provider-azure -n kube-system --timeout=120s" ]

  # -----------------------------------------------------------------------
  # Install Azure CLI (needed when az connectedk8s connect runs via run-command)
  # -----------------------------------------------------------------------
  - [ bash, -c, "curl -sL https://aka.ms/InstallAzureCLIDeb | bash" ]
'''

var k9sBlock = installK9s ? '''
  # Install k9s — terminal K8s UI
  - [ bash, -c, "K9S_VER=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name) && curl -sL https://github.com/derailed/k9s/releases/download/${K9S_VER}/k9s_Linux_amd64.tar.gz | tar -xz -C /usr/local/bin k9s" ]
''' : ''

var mqttuiBlock = installMqttui ? '''
  # Install mqttui — terminal MQTT client
  - [ bash, -c, "MQTTUI_VER=$(curl -s https://api.github.com/repos/EdJoPaTo/mqttui/releases/latest | jq -r .tag_name) && curl -sL https://github.com/EdJoPaTo/mqttui/releases/download/${MQTTUI_VER}/mqttui-${MQTTUI_VER}-x86_64-unknown-linux-musl.tar.gz | tar -xz -C /usr/local/bin mqttui" ]
''' : ''

var cloudInitFooter = '''
  # Signal bootstrap complete — post-provision.ps1 polls for this file
  - [ bash, -c, "touch /tmp/k3s-ready" ]
'''

var cloudInitContent = '${cloudInitBase}${k9sBlock}${mqttuiBlock}${cloudInitFooter}'
var cloudInitBase64 = base64(cloudInitContent)

// ---------------------------------------------------------------------------
// NIC
// ---------------------------------------------------------------------------

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIpId
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsgId
    }
  }
}

// ---------------------------------------------------------------------------
// Virtual Machine
// ---------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 64
      }
    }
    osProfile: {
      computerName: clusterName
      adminUsername: adminUsername
      customData: cloudInitBase64
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output systemIdentityPrincipalId string = vm.identity.principalId
