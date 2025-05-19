/*
  This Bicep template deploys a secure web application infrastructure on Azure.
  It includes the following resources:
  - Log Analytics Workspace for monitoring
  - Virtual Network with subnets for the web app and private endpoints
  - App Service Plan and Web App with VNet integration and private endpoint
  - Azure Front Door with WAF policy for secure content delivery
  - Private DNS zone for the web app

  The template emphasizes security by implementing:
  - VNet integration for the web app
  - Private endpoints for secure access
  - IP restrictions to allow traffic only from the VNet and Azure Front Door
  - Web Application Firewall (WAF) policy with custom rules

  Parameters allow for customization of resource names, locations, and network configurations.
*/


@description('The name of the web app that you wish to create.')
param webAppName string

@description('The name of the App Service plan.')
param appServicePlanName string

@description('The name of the Front Door profile.')
param frontDoorName string

@description('The name of the WAF policy.')
param wafPolicyName string

@description('The location for all resources.')
param location string = resourceGroup().location

@description('The SKU of App Service Plan.')
param sku string = 'B1'

@description('Common tags for all resources')
param tags object = {}

@description('Log Analytics Workspace quota')
param logQuota int

@description('Log Analytics Workspace retention time in days')
param logRetentionDays int

@description('Log Analytics Workspace SKU (e.g., PerGB2018)')
param logPlan string

@description('VNet address prefix (e.g., 10.0.0.0/16)')
param vnetAddressPrefix string

@description('WebApp Subnet address prefix (e.g., 10.0.1.0/24)')
param vnetSubnetWebappPrefix string

@description('Private Endpoint Subnet address prefix (e.g., 10.0.2.0/24)')
param vnetSubnetPrivatePrefix string

@description('The tag of the Docker image to deploy')
param imageTag string

@description('Allows IP address')
param allowIpRange string

@minLength(5)
@maxLength(50)
@description('Provide a globally unique name of your Azure Container Registry')
param acrName string = 'acr${uniqueString(resourceGroup().id)}'

@description('Provide a tier of your Azure Container Registry.')
param acrSku string = 'Basic'

var frontDoorSkuName = 'Premium_AzureFrontDoor'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'logAnalyticsWorkspace-${webAppName}'
  location: location
  properties: {
    sku: {
      name: logPlan
    }
    retentionInDays: logRetentionDays
    workspaceCapping: {
      dailyQuotaGb: logQuota
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
  tags: tags
}

resource acrResource 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: false
  }
}

resource registryRepositoryAdmin 'Microsoft.ContainerRegistry/registries/scopeMaps@2024-11-01-preview' = {
  parent: acrResource
  name: 'webapp-repo-admin'
  properties: {
    description: 'Can perform all read, write and delete operations on the registry'
    actions: [
      'repositories/*/metadata/read'
      'repositories/*/metadata/write'
      'repositories/*/content/read'
      'repositories/*/content/write'
      'repositories/*/content/delete'
    ]
  }  
}

resource registryRepositoryPull 'Microsoft.ContainerRegistry/registries/scopeMaps@2024-11-01-preview' = {
  parent: acrResource
  name: 'webapp-repo-pull'
  properties: {
    description: 'Can pull any repository of the registry'
    actions: [
      'repositories/*/content/read'
      'repositories/*/metadata/read'
    ]
  }  
}

resource registryRepositoryPush 'Microsoft.ContainerRegistry/registries/scopeMaps@2024-11-01-preview' = {
  parent: acrResource
  name: 'webapp-repo-push'
  properties: {
    description: 'Can push to any repository of the registry'
    actions: [
      'repositories/*/content/read'
      'repositories/*/content/write'
    ]
  }  
}

resource registryRepositoryPullPush 'Microsoft.ContainerRegistry/registries/scopeMaps@2024-11-01-preview' = {
  parent: acrResource
  name: 'webapp-repo-pullpush'
  properties: {
    description: 'Can pull and push to any repository of the registry'
    actions: [
      'repositories/*/content/read'
      'repositories/*/content/write'
      'repositories/*/metadata/read'
      'repositories/*/metadata/write'
    ]
  }  
}


resource webAppVnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'vnet-${webAppName}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'subnet-webapp'
        id: 'subnet-webapp'
        properties: {
          addressPrefix: vnetSubnetWebappPrefix          
          delegations: [
            {
              name: 'webappDelegation'
              id: 'webappDelegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
              type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'     
          
        }
      }
      {
        name: 'subnet-privateendpoint'
        id: 'subnet-privateendpoint'
        properties: {
          addressPrefix: vnetSubnetPrivatePrefix          
          delegations: []
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
  }
  tags: tags
}

resource appServicePlan 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: sku
    tier: sku
    size: 'B1'
    family: 'B'
    capacity: 0
  }
  kind: 'linux'
  properties: {
    perSiteScaling: false
    elasticScaleEnabled: false
    maximumElasticWorkerCount: 1
    isSpot: false
    reserved: true
    isXenon: false
    hyperV: false
    targetWorkerCount: 0
    targetWorkerSizeId: 0
    zoneRedundant: false
  }
}

resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enabled: true
    hostNameSslStates: [
      {
        name: '${webAppName}.azurewebsites.net'
        hostType: 'Standard'
        sslState: 'Disabled'
      }
      {
        name: '${webAppName}.scm.azurewebsites.net'
        hostType: 'Repository'
        sslState: 'Disabled'
      }
    ]
    serverFarmId: appServicePlan.id
    reserved: true
    isXenon: false
    hyperV: false
    dnsConfiguration: {}
    vnetRouteAllEnabled: true
    vnetImagePullEnabled: false
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: 'DOCKER|${acrName}.azurecr.io/${webAppName}:${imageTag}'
      acrUseManagedIdentityCreds: false
      appSettings: [
        {
          name: 'DOCKER_CUSTOM_IMAGE_NAME'
          value: '${acrName}.azurecr.io/${webAppName}:${imageTag}'
        }
    ]
      alwaysOn: true
      http20Enabled: true
      functionAppScaleLimit: 0
      minimumElasticInstanceCount: 1                
    }
    scmSiteAlsoStopped: false
    clientAffinityEnabled: true
    clientCertMode: 'Required'
    hostNamesDisabled: false
    ipMode: 'IPv4'
    vnetBackupRestoreEnabled: false
    customDomainVerificationId: ''
    containerSize: 0
    dailyMemoryTimeQuota: 0
    httpsOnly: false
    endToEndEncryptionEnabled: false
    redundancyMode: 'None'
    storageAccountRequired: false
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: webAppVnet.properties.subnets[0].id    
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: '${webAppName}.azurewebsites.net'
  location: 'global'
}

resource privateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${webAppName}-vnetlink'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: webAppVnet.id
    }
  }
}

// Access Restrictions to allow traffic from VNet
resource accessRestriction 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: webApp
  name: 'web'
  properties: {
    numberOfWorkers: 1
    defaultDocuments: [
      'Default.htm'
      'Default.html'
      'Default.asp'
      'index.htm'
      'index.html'
      'iisstart.htm'
      'default.aspx'
      'index.php'
      'hostingstart.html'
    ]
    netFrameworkVersion: 'v4.0'
    linuxFxVersion: 'DOCKER|${acrName}.azurecr.io/${webAppName}:${imageTag}'
    requestTracingEnabled: true
    remoteDebuggingEnabled: false
    httpLoggingEnabled: true
    acrUseManagedIdentityCreds: false
    logsDirectorySizeLimit: 100
    detailedErrorLoggingEnabled: true
    publishingUsername: 'webapp'
    scmType: 'None'
    use32BitWorkerProcess: true
    webSocketsEnabled: false
    alwaysOn: true
    managedPipelineMode: 'Integrated'
    virtualApplications: [
      {
        virtualPath: '/'
        physicalPath: 'site\\wwwroot'
        preloadEnabled: true
      }
    ]
    loadBalancing: 'LeastRequests'
    experiments: {
      rampUpRules: []
    }
    autoHealEnabled: false
    vnetName: webAppVnet.name   
    vnetRouteAllEnabled: true
    vnetPrivatePortsCount: 0
    publicNetworkAccess: 'Enabled'    
    ipSecurityRestrictions: [
      {
        ipAddress: 'Any'
        action: 'Deny'
        priority: 2147483647
        name: 'Deny all'
        description: 'Deny all access'
      }
      {
        name: 'AllowAzureFrontDoor'
        priority: 101
        action: 'Allow'
        ipAddress: allowIpRange        
      }
      {
        ipAddress: 'AzureFrontDoor.Backend'
        action: 'Allow'
        tag: 'ServiceTag'
        priority: 100
        name: 'test'
      }        
    ]
    ipSecurityRestrictionsDefaultAction: 'Deny'
    scmIpSecurityRestrictions: [
      {
        ipAddress: 'Any'
        action: 'Allow'
        priority: 2147483647
        name: 'Allow all'
        description: 'Allow all access'
      }
    ]
    scmIpSecurityRestrictionsDefaultAction: 'Allow'
    scmIpSecurityRestrictionsUseMain: false
    http20Enabled: true
    minTlsVersion: '1.2'
    scmMinTlsVersion: '1.2'
    ftpsState: 'FtpsOnly'
    preWarmedInstanceCount: 0
    elasticWebAppScaleLimit: 0
    functionsRuntimeScaleMonitoringEnabled: false
    minimumElasticInstanceCount: 1
    azureStorageAccounts: {}
  }
}



resource frontDoorProfile 'Microsoft.Cdn/profiles@2021-06-01' = {
  name: frontDoorName
  location: 'global'
  sku: {
    name: frontDoorSkuName
  }
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2021-06-01' = {
  name: '${frontDoorName}-endpoint'
  parent: frontDoorProfile
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource frontDoorOriginGroup 'Microsoft.Cdn/profiles/originGroups@2021-06-01' = {
  name: '${frontDoorName}-origingroup'
  parent: frontDoorProfile
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 180
    }
    sessionAffinityState: 'Disabled'
  }
}

resource frontDoorOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2021-06-01' = {
  name: '${frontDoorName}-origin'
  parent: frontDoorOriginGroup
  properties: {
    hostName: '${webAppName}.azurewebsites.net'
    httpPort: 80
    httpsPort: 443
    originHostHeader: '${webAppName}.azurewebsites.net'
    priority: 1
    weight: 1000
    enabledState: 'Enabled'    
    enforceCertificateNameCheck: true
  }  
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2021-06-01' = {
  name: '${frontDoorName}-route'
  parent: frontDoorEndpoint  
  properties: {
    originGroup: {
      id: frontDoorOriginGroup.id
    }
    originPath: '/'
    ruleSets: []
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    frontDoorOrigin
  ]
}

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: 'global'
  sku: {
    name: frontDoorSkuName
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
    }
    customRules: {
      rules: [
        {
          name: 'AllowByIpRange'
          priority: 101
          enabledState: 'Enabled'
          ruleType: 'MatchRule'
          action: 'Allow'
          matchConditions: [
            {
              matchVariable: 'RemoteAddr'
              operator: 'IPMatch'
              matchValue: [
                allowIpRange
              ]
            }
          ]
        }
        {
          name: 'denyforpublic'
          enabledState: 'Enabled'
          priority: 100
          ruleType: 'MatchRule'
          rateLimitDurationInMinutes: 1
          rateLimitThreshold: 100
          matchConditions: [
            {
              matchVariable: 'RemoteAddr'
              operator: 'IPMatch'
              negateCondition: true
              matchValue: [
                allowIpRange
              ]
              transforms: []
            }
          ]
          action: 'Block'
          groupBy: []
        }
      ]
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'DefaultRuleSet'
          ruleSetVersion: '1.0'
        }
      ]
    }
  }
}

resource frontDoorSecurityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2021-06-01' = {
  parent: frontDoorProfile
  name: '${frontDoorName}-securitypolicy'
  
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: wafPolicy.id // Use the ID of the deployed WAF policy
      }
      associations: [
        {
          domains: [
            {
              id: frontDoorEndpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}		
