// rawcut Azure Infrastructure
// Deploy: az deployment group create --resource-group rawcut-rg --template-file main.bicep --parameters parameters.json

param location string = resourceGroup().location
param environmentName string = 'rawcut'

// Storage Account (Blob + CDN)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${environmentName}storage'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// Blob containers
resource hotContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccount.name}/default/media-hot'
  properties: {
    publicAccess: 'None'
  }
}

resource coolContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccount.name}/default/media-cool'
  properties: {
    publicAccess: 'None'
  }
}

resource thumbnailContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccount.name}/default/thumbnails'
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle management: Hot -> Cool after 30 days
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  name: '${storageAccount.name}/default'
  properties: {
    policy: {
      rules: [
        {
          name: 'moveToCool'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['media-hot/']
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Container App Environment
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${environmentName}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// Log Analytics for observability
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${environmentName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Container App (API server)
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${environmentName}-api'
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'http'
      }
      secrets: [
        {
          name: 'azure-storage-connection'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: 'rawcut-api:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'AZURE_STORAGE_CONNECTION_STRING'
              secretRef: 'azure-storage-connection'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// Outputs
output storageAccountName string = storageAccount.name
output containerAppUrl string = containerApp.properties.configuration.ingress.fqdn
output logAnalyticsId string = logAnalytics.id
