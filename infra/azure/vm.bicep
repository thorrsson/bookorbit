targetScope = 'resourceGroup'

@minLength(3)
@maxLength(15)
param name string = 'bookorbit'
param location string = resourceGroup().location
param vmSize string = 'Standard_D2as_v6'

@allowed(['NVMe', 'SCSI'])
param diskControllerType string = 'NVMe'
param adminUsername string = 'azureuser'
@description('Public SSH key, never the private key.')
param sshPublicKey string
@description('Administrator IPv4 CIDR. The deployment wrapper requires /24 or narrower.')
param sshSourceCidr string
@minValue(32)
param dataDiskSizeGB int = 128

resource nsg 'Microsoft.Network/networkSecurityGroups@2026-03-01' = {
  name: '${name}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'ssh'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'web'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
    ]
  }
}

resource network 'Microsoft.Network/virtualNetworks@2026-03-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.40.0.0/24']
    }
    subnets: [
      {
        name: 'vm'
        properties: {
          addressPrefix: '10.40.0.0/24'
          networkSecurityGroup: { id: nsg.id }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2026-03-01' = {
  name: '${name}-ip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2026-03-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: network.properties.subnets[0].id }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

resource dataDisk 'Microsoft.Compute/disks@2026-03-02' = {
  name: '${name}-data'
  location: location
  sku: { name: 'Premium_LRS' }
  properties: {
    creationData: { createOption: 'Empty' }
    diskSizeGB: dataDiskSizeGB
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: '${name}-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(loadTextContent('./bootstrap-vm.sh'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      diskControllerType: diskControllerType
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-26_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      dataDisks: [
        {
          lun: 0
          name: dataDisk.name
          createOption: 'Attach'
          deleteOption: 'Detach'
          managedDisk: { id: dataDisk.id }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

output ipAddress string = publicIp.properties.ipAddress
output sshTarget string = '${adminUsername}@${publicIp.properties.ipAddress}'
output virtualNetworkId string = network.id
output subnetId string = network.properties.subnets[0].id
output vmName string = vm.name
