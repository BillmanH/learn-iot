// ============================================================================
// Network module: VNet, Subnet, NSG, Public IP
// ============================================================================

param location string
param clusterName string
param openSshPort bool = true
param tags object = {}

var vnetName = '${clusterName}-vnet'
var subnetName = '${clusterName}-subnet'
var nsgName = '${clusterName}-nsg'
var publicIpName = '${clusterName}-pip'

// NSG security rules — SSH is conditional on openSshPort
var sshRule = openSshPort ? [
  {
    name: 'allow-ssh'
    properties: {
      priority: 1000
      protocol: 'Tcp'
      access: 'Allow'
      direction: 'Inbound'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
      description: 'Allow SSH inbound (set OPEN_SSH_PORT=false to disable)'
    }
  }
] : []

var baseRules = [
  {
    name: 'allow-k8s-api-inbound'
    properties: {
      priority: 1100
      protocol: 'Tcp'
      access: 'Allow'
      direction: 'Inbound'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '6443'
      description: 'Allow K3s API server within VNet'
    }
  }
  {
    name: 'deny-all-inbound'
    properties: {
      priority: 4096
      protocol: '*'
      access: 'Deny'
      direction: 'Inbound'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      description: 'Deny all other inbound (explicit default deny)'
    }
  }
]

var securityRules = concat(sshRule, baseRules)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: securityRules
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower(clusterName)
    }
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output subnetId string = vnet.properties.subnets[0].id
output nsgId string = nsg.id
output publicIpId string = publicIp.id
output publicIpAddress string = publicIp.properties.ipAddress
output fqdn string = publicIp.properties.dnsSettings.fqdn
