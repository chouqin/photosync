@description('Location for all resources')
param location string = resourceGroup().location

@description('Storage account name (must be globally unique, 3-24 lowercase alphanum)')
param storageAccountName string = 'photosync${uniqueString(resourceGroup().id)}'

@description('Storage tier for new blobs: Cool or Hot')
param defaultBlobTier string = 'Cool'

@description('Days before moving blob to Archive tier')
param archiveAfterDays int = 180

@description('Days before deleting soft-deleted blobs permanently')
param deleteAfterDays int = 7

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: defaultBlobTier
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Blob service
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: deleteAfterDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: deleteAfterDays
    }
  }
}

// Photos container
resource photosContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'photos'
  properties: {
    publicAccess: 'None'
  }
}

// Backups container (for SQLite DB backups)
resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'backups'
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle management policy
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'photos-archive-old'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'photos/'
              ]
            }
            actions: {
              baseBlob: {
                tierToArchive: {
                  daysAfterModificationGreaterThan: archiveAfterDays
                }
                delete: {
                  daysAfterModificationGreaterThan: 3650 // 10 years, adjust as needed
                }
              }
            }
          }
        }
        {
          name: 'cleanup-deleted-blobs'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'photos/'
              ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 3650
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Outputs
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output photosContainerName string = photosContainer.name
output backupsContainerName string = backupsContainer.name
