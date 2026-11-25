targetScope = 'resourceGroup'

param name string = 'bookorbit'
param location string = resourceGroup().location
param environmentName string = '${name}-apps'
param appImage string
param appUrl string
@description('Existing or explicitly desired hostname/certificate bindings. The wrapper preserves live bindings on updates.')
param customDomains array = []
param puid string = '1000'
param pgid string = '1000'
@minValue(128)
@maxValue(3072)
param nodeMaxOldSpaceSize int = 2048
@secure()
param databaseUrl string
@secure()
param jwtSecret string
@secure()
param setupBootstrapToken string
@secure()
param emailEncryptionKey string
@secure()
param migrationEncryptionKey string
@secure()
param bookRequestEncryptionKey string

resource environment 'Microsoft.App/managedEnvironments@2026-07-01' existing = {
  name: environmentName
}

resource app 'Microsoft.App/containerApps@2026-07-01' = {
  name: name
  location: location
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        allowInsecure: false
        targetPort: 3000
        transport: 'auto'
        customDomains: customDomains
      }
      secrets: [
        { name: 'database-url', value: databaseUrl }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'setup-token', value: setupBootstrapToken }
        { name: 'email-key', value: emailEncryptionKey }
        { name: 'migration-key', value: migrationEncryptionKey }
        { name: 'requests-key', value: bookRequestEncryptionKey }
      ]
    }
    template: {
      terminationGracePeriodSeconds: 60
      // In-process schedulers, file watchers and Socket.IO are not multi-replica safe yet.
      scale: { minReplicas: 1, maxReplicas: 1 }
      containers: [
        {
          name: 'bookorbit'
          image: appImage
          resources: { cpu: 2, memory: '4Gi' }
          env: [
            { name: 'NODE_ENV', value: 'production' }
            { name: 'PORT', value: '3000' }
            { name: 'HOST', value: '0.0.0.0' }
            { name: 'APP_URL', value: appUrl }
            { name: 'CLIENT_URL', value: appUrl }
            { name: 'APP_DATA_PATH', value: '/data' }
            { name: 'BOOK_DOCK_PATH', value: '/books/.book-dock' }
            { name: 'LIBRARY_BROWSE_ROOT', value: '/books' }
            { name: 'PUID', value: puid }
            { name: 'PGID', value: pgid }
            { name: 'NODE_MAX_OLD_SPACE_SIZE', value: string(nodeMaxOldSpaceSize) }
            { name: 'DATABASE_URL', secretRef: 'database-url' }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'SETUP_BOOTSTRAP_TOKEN', secretRef: 'setup-token' }
            { name: 'EMAIL_ENCRYPTION_KEY', secretRef: 'email-key' }
            { name: 'MIGRATION_ENCRYPTION_KEY', secretRef: 'migration-key' }
            { name: 'BOOK_REQUEST_ENCRYPTION_KEY', secretRef: 'requests-key' }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/api/v1/health', port: 3000, scheme: 'HTTP' }
              periodSeconds: 180
              timeoutSeconds: 5
              failureThreshold: 10
            }
            {
              type: 'Readiness'
              httpGet: { path: '/api/v1/health', port: 3000, scheme: 'HTTP' }
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Liveness'
              tcpSocket: { port: 3000 }
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
          volumeMounts: [
            { volumeName: 'books', mountPath: '/books' }
            { volumeName: 'data', mountPath: '/data' }
          ]
        }
      ]
      volumes: [
        { name: 'books', storageName: 'books', storageType: 'NfsAzureFile' }
        { name: 'data', storageName: 'data', storageType: 'NfsAzureFile' }
      ]
    }
  }
}

output url string = 'https://${app.properties.configuration.ingress.fqdn}'
