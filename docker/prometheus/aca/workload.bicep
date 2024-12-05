param acaName string
param acaTags string = '{ "CostCentre": "DEV", "Department": "RESEARCH", "WorkloadType": "TEST" }'

param appVersion string

param petClinicAppUserManagedIdentityName string = '${acaName}-pet-clinic-app-identity'
param appName string = 'prometheus'
param appClientId string
param containerImage string

//param certificateId string = ''

param containerRegistryName string = replace(replace(acaName,'_', ''),'-','')
param containerRegistrySubscriptionId string = subscription().id
param containerRegistryRG string = resourceGroup().name

// param dnsZoneName string = ''
// param petClinicDnsZoneName string = ''
// param parentDnsZoneName string = ''

var acaTagsArray = json(empty(acaTags) ? '{ "CostCentre": "DEV", "Department": "RESEARCH", "WorkloadType": "TEST" }' : acaTags)

var containerRegistrySubscriptionIdVar = (containerRegistrySubscriptionId == '')
  ? subscription().id
  : containerRegistrySubscriptionId
var containerRegistryRGVar = (containerRegistryRG == '') ? resourceGroup().name : containerRegistryRG

param location string

resource petClinicAppUserManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: petClinicAppUserManagedIdentityName
}

resource kvSecretPetClinicAppInsightsConnectionString 'Microsoft.KeyVault/vaults/secrets@2024-04-01-preview' existing = {
  parent: keyVault
  name: 'PET-CLINIC-APP-INSIGHTS-CONNECTION-STRING'
}

resource kvSecretPetClinicAppInsightsInstrumentationKey 'Microsoft.KeyVault/vaults/secrets@2024-04-01-preview' existing = {
  parent: keyVault
  name: 'PET-CLINIC-APP-INSIGHTS-INSTRUMENTATION-KEY'
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: '${acaName}-kv'
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
  scope: resourceGroup(containerRegistrySubscriptionIdVar, containerRegistryRGVar)
}

resource acaEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: acaName
}

resource acaApp 'Microsoft.App/containerApps@2024-03-01' = {
   name: appName
   tags: acaTagsArray
   identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
         '${petClinicAppUserManagedIdentity.id}': {}
      }
   }
   properties: {
      environmentId: acaEnvironment.id
      configuration: {
          activeRevisionsMode: 'Multiple'
          secrets: [
            {
              name: toLower(kvSecretPetClinicAppInsightsConnectionString.name)
              keyVaultUrl: kvSecretPetClinicAppInsightsConnectionString.properties.secretUri
              identity: petClinicAppUserManagedIdentity.id
            }
            {
              name: toLower(kvSecretPetClinicAppInsightsInstrumentationKey.name)
              keyVaultUrl: kvSecretPetClinicAppInsightsInstrumentationKey.properties.secretUri
              identity: petClinicAppUserManagedIdentity.id
            }
          ]
          registries: [
            {
              server: '${containerRegistry.name}.azurecr.io'
              identity: petClinicAppUserManagedIdentity.id
            }
          ]
          ingress: {
            targetPort: 9090
            external: false
            // external: true
            // clientCertificateMode: 'ignore'
            // customDomains: empty(certificateId) ? [
            //   {
            //     name: '${appName}.${petClinicDnsZoneName}.${dnsZoneName}.${parentDnsZoneName}'
            //     bindingType: 'Disabled'
            //   }
            // ] : [
            //   {
            //     name: '${appName}.${petClinicDnsZoneName}.${dnsZoneName}.${parentDnsZoneName}'
            //     certificateId: certificateId
            //     bindingType:'SniEnabled'
            //   }
            // ]
          }
      }
      template: {
        revisionSuffix: replace(appVersion,'.','-')
        scale: {
          minReplicas: 1
          maxReplicas: 10
          rules: [
            {
              name: 'http-rule'
              http: {
                metadata: {
                  concurrentRequests: '100'
                }
              }
            }
          ]
        }
        containers: [
            {
              image: containerImage
              name: appName
              env: [
                {
                  name: 'CONFIG_SERVER_URL'
                  value: 'http://config-server:8888'
                }
                {
                  name: 'PORT'
                  value: '9090'
                }
                {
                  name: 'ENVIRONMENT'
                  value: 'ACA'
                }
                {
                  name: 'AZURE_TENANT_ID'
                  value: tenant().tenantId
                }
                {
                  name: 'AZURE_CLIENT_ID'
                  value: appClientId
                }
                {
                  name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
                  secretRef: toLower(kvSecretPetClinicAppInsightsConnectionString.name)
                }
                {
                  name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
                  secretRef: toLower(kvSecretPetClinicAppInsightsInstrumentationKey.name)
                }
                {
                  name:  'APPLICATIONINSIGHTS_CONFIGURATION_CONTENT'
                  value: '{ "role": { "name": "prometheus" } }'
                }
              ]
              resources: {
                 cpu: json('0.5')
                 memory: '1.0Gi'
              }
              probes: [
                {
                  type: 'Startup'
                  httpGet:{
                    path: '/-/healthy'
                    port: 9090
                  }
                  initialDelaySeconds: 30
                  successThreshold: 1
                  failureThreshold: 3
                  periodSeconds: 20
                }
                {
                  type: 'Readiness'
                  httpGet:{
                    path: '/-/healthy'
                    port: 9090
                  }
                  initialDelaySeconds: 30
                  successThreshold: 1
                  failureThreshold: 3
                  periodSeconds: 20
                }
                {
                  type:'Liveness'
                  httpGet:{
                    path: '/-/healthy'
                    port: 9090
                  }
                  initialDelaySeconds: 60
                  successThreshold: 1
                  failureThreshold: 3
                  periodSeconds: 20
                }
              ]
            }
        ]
      }
    }
    location: location
}

// module dnsRecordCname './components/dns-record-cname.bicep' = {
//   name: 'dns-record-cname'
//   params: {
//     dnsZoneName: '${petClinicDnsZoneName}.${dnsZoneName}.${parentDnsZoneName}'
//     dnsRecordName: appName
//     dnsRecordValue: acaApp.properties.configuration.ingress.fqdn
//   }
// }

// resource acaManagedCertificate 'Microsoft.App/managedEnvironments/managedCertificates@2024-03-01' = {
//   parent: acaEnvironment
//   name: 'managed-certificate-${appName}'
//   dependsOn: [
//     dnsRecordCname
//   ]
//   tags: acaTagsArray
//   properties: {
//     domainControlValidation: 'CNAME'
//     subjectName: '${appName}.${petClinicDnsZoneName}.${dnsZoneName}.${parentDnsZoneName}'
//   }
//   location: location
// }
