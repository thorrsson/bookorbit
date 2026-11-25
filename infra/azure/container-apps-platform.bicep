targetScope = 'resourceGroup'

@minLength(3)
@maxLength(15)
param name string = 'bookorbit'
param location string = resourceGroup().location
@secure()
@minLength(24)
param postgresPassword string
param postgresUser string = 'bookorbit'
param postgresDatabase string = 'bookorbit'
@minValue(100)
param fileShareSizeGB int = 100
@minValue(32)
param postgresStorageGB int = 128
@description('Optional source VM VNet for private DNS and one half of migration peering.')
param migrationVirtualNetworkId string = ''
@description('Optional source VM subnet, with the Microsoft.Storage service endpoint enabled.')
param migrationSubnetId string = ''

var suffix = uniqueString(resourceGroup().id, name)
var storageName = 'bo${suffix}'

resource network 'Microsoft.Network/virtualNetworks@2026-03-01' = {
  name: '${name}-apps-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.42.0.0/16'] }
    subnets: [
      {
        name: 'containers'
        properties: {
          addressPrefix: '10.42.0.0/23'
          delegations: [
            {
              name: 'container-apps'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
          serviceEndpoints: [{ service: 'Microsoft.Storage' }]
        }
      }
      {
        name: 'database'
        properties: {
          addressPrefix: '10.42.2.0/24'
          delegations: [
            {
              name: 'postgresql'
              properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' }
            }
          ]
        }
      }
    ]
  }
}

resource migrationPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2026-03-01' = if (!empty(migrationVirtualNetworkId)) {
  parent: network
  name: 'migration-source'
  properties: {
    allowVirtualNetworkAccess: true
    remoteVirtualNetwork: { id: migrationVirtualNetworkId }
  }
}

resource dns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'private.postgres.database.azure.com'
  location: 'global'
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dns
  name: 'container-apps'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: network.id }
  }
}

resource migrationDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(migrationVirtualNetworkId)) {
  parent: dns
  name: 'migration-source'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: migrationVirtualNetworkId }
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2026-10-01' = {
  name: '${name}-${suffix}-pg'
  location: location
  sku: { name: 'Standard_D2ds_v6', tier: 'GeneralPurpose' }
  properties: {
    version: '18'
    administratorLogin: postgresUser
    administratorLoginPassword: postgresPassword
    createMode: 'Default'
    storage: { storageSizeGB: postgresStorageGB, autoGrow: 'Enabled' }
    backup: { backupRetentionDays: 14, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: {
      delegatedSubnetResourceId: network.properties.subnets[1].id
      privateDnsZoneArmResourceId: dns.id
      publicNetworkAccess: 'Disabled'
    }
  }
  dependsOn: [dnsLink]
}

resource extensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2026-10-01' = {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    value: 'uuid-ossp,pg_trgm,unaccent,vector'
    source: 'user-override'
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2026-10-01' = {
  parent: postgres
  name: postgresDatabase
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
}

resource storage 'Microsoft.Storage/storageAccounts@2026-09-01' = {
  name: storageName
  location: location
  kind: 'FileStorage'
  sku: { name: 'Premium_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    // Container Apps NFS mounts do not support encryption in transit.
    supportsHttpsTrafficOnly: false
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      virtualNetworkRules: concat(
        [
          { id: network.properties.subnets[0].id, action: 'Allow' }
        ],
        empty(migrationSubnetId)
          ? []
          : [
              { id: migrationSubnetId, action: 'Allow' }
            ]
      )
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2026-09-01' = {
  parent: storage
  name: 'default'
}

resource shares 'Microsoft.Storage/storageAccounts/fileServices/shares@2026-09-01' = [
  for share in ['books', 'data']: {
    parent: fileService
    name: share
    properties: {
      enabledProtocols: 'NFS'
      rootSquash: 'NoRootSquash'
      shareQuota: fileShareSizeGB
    }
  }
]

resource logs 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: '${name}-apps-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource environment 'Microsoft.App/managedEnvironments@2026-07-01' = {
  name: '${name}-apps'
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: network.properties.subnets[0].id
      internal: false
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource mounts 'Microsoft.App/managedEnvironments/storages@2026-07-01' = [
  for (share, index) in ['books', 'data']: {
    parent: environment
    name: share
    properties: {
      nfsAzureFile: {
        accessMode: 'ReadWrite'
        server: '${storage.name}.file.${az.environment().suffixes.storage}'
        shareName: shares[index].name
      }
    }
  }
]

output environmentName string = environment.name
output virtualNetworkId string = network.id
output storageAccountName string = storage.name
output postgresHost string = postgres.properties.fullyQualifiedDomainName
output postgresUser string = postgresUser
output postgresDatabase string = database.name
