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
      'repositories/webapp/repository/read'
      'repositories/webapp/repository/write'
      'repositories/webapp/repository/delete'
      'repositories/webapp/repository/metadata/read'
      'repositories/webapp/repository/metadata/write'
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

resource registryWebHook 'Microsoft.ContainerRegistry/registries/webhooks@2024-11-01-preview' = {
  parent: acrResource
  name: 'webappwebhook'
  location: location
  properties: {
    status: 'enabled'
    scope: 'webapp/*'
    actions: [
      'push'      
    ]
    serviceUri: 'https://webapp.azurewebsites.net/api/webhook'
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
    privateEndpointVNetPolicies: 'Disabled'
    subnets: [
      {
        name: 'subnet-webapp'
        id: 'subnet-webapp'
        properties: {
          addressPrefix: vnetSubnetWebappPrefix
          routeTable: {
            id: webAppRouteTable.id
          }
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
          routeTable: {
            id: webAppRouteTable.id
          }
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

resource webAppVnetSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-04-01' = {
  parent: webAppVnet
  name: 'subnet-webapp'
  properties: {
    addressPrefix: vnetSubnetWebappPrefix
    routeTable: {
      id: webAppRouteTable.id
    }
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

resource webAppRouteTable 'Microsoft.Network/routeTables@2023-04-01' = {
  name: '${webAppName}-routeTable'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'route-to-webapp'
        id: 'route-to-webapp'
        properties: {
          addressPrefix: vnetSubnetWebappPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '${webAppName}.azurewebsites.net'
        }
      }
    ]
  }
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
  kind: 'app, linux, container'
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
      linuxFxVersion: 'DOCKER|${acrName}.azurecr.io/${webAppName}:latest'
      acrUseManagedIdentityCreds: false
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
    virtualNetworkSubnetId: webAppVnet.properties.subnets[0].id    
  }
}

resource webAppVnetIntegration 'Microsoft.Web/sites/networkConfig@2021-03-01' = {
  parent: webApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: webAppVnet.properties.subnets[0].id
  }
}

resource webAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: '${webAppName}-pe'
  location: location
  properties: {
    subnet: {
      id: webAppVnet.properties.subnets[1].id 
    }
    privateLinkServiceConnections: [
      {
        name: '${webAppName}-plsc'
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: [
            'sites'
          ]
          privateLinkServiceConnectionState: {
            status: 'Approved'
            description: 'Private endpoint connection approved.'
            actionsRequired: 'None'
          }
        }
      }
    ]
    manualPrivateLinkServiceConnections: []
    ipConfigurations: []
    customDnsConfigs: []
  }
}

resource webAppPrivateEndpointConnection 'Microsoft.Web/sites/privateEndpointConnections@2024-04-01' = {
  parent: webApp
  name: '${webAppName}-peconnection'
  location: location
  properties: {
    privateLinkServiceConnectionState: {
      status: 'Approved'
      description: 'Private endpoint connection approved.'
      actionsRequired: 'None'
    }
    ipAddress: 'allowIpRange'
    privateEndpoint: {
      id: webAppPrivateEndpoint.id
    }
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

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-05-01' = {
  parent: webAppPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
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
    linuxFxVersion: 'DOCKER|${acrName}.azurecr.io/${webAppName}:latest'
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
    vnetNamed: webAppVnet.name
    vnetRouteAllEnabled: true
    vnetPrivatePortsCount: 0    
    ipSecurityRestrictions: [
      {
        ipAddress: 'Any'
        action: 'Allow'
        priority: 2147483647
        name: 'Allow all'
        description: 'Allow all access'
      }
      {
        name: 'AllowAzureFrontDoor'
        priority: 200
        action: 'Allow'
        ipAddress: allowIpRange        
      }         
    ]
    scmIpSecurityRestrictions: [
      {
        ipAddress: 'Any'
        action: 'Allow'
        priority: 2147483647
        name: 'Allow all'
        description: 'Allow all access'
      }
    ]
    scmIpSecurityRestrictionsUseMain: false
    http20Enabled: true
    minTlsVersion: '1.2'
    scmMinTlsVersion: '1.2'
    ftpsState: 'Disabled'
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
    sharedPrivateLinkResource: {
      privateLink: {
        id: webAppPrivateEndpoint.id
      }
      groupId: 'sites'
      privateLinkLocation: {
        id: webAppPrivateEndpoint.id
      }
    }
    enforceCertificateNameCheck: true
  }  
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2021-06-01' = {
  name: '${frontDoorName}-route'
  parent: frontDoorEndpoint  
  properties: {
    customDomains: [
      {
        id: frontDoorEndpoint.id        
      }
    ]
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
          priority: 1
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
