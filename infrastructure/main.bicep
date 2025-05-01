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
  }
  tags: tags
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
        name: 'snet-webapp'
        properties: {
          addressPrefix: vnetSubnetWebappPrefix
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Web'
            }
          ]
        }
      }
      {
        name: 'snet-privateendpoint'
        properties: {
          addressPrefix: vnetSubnetPrivatePrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
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
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource webApp 'Microsoft.Web/sites@2021-03-01' = {
  name: webAppName
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'NODE|14-lts'
      alwaysOn: true
      vnetRouteAllEnabled: false
    }
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
        }
      }
    ]
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
    }
    healthProbeSettings: {
      probePath: '/health'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 60
    }
  }
}

resource frontDoorOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2021-06-01' = {
  name: '${frontDoorName}-origin'
  parent: frontDoorOriginGroup
  properties: {
    hostName: '${webAppName}.privatelink.azurefd.net'
    httpPort: 80
    httpsPort: 443
    originHostHeader: webApp.properties.defaultHostName
    priority: 1
    weight: 1000
  }
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2021-06-01' = {
  name: '${frontDoorName}-route'
  parent: frontDoorEndpoint
  dependsOn: [
    frontDoorOrigin
  ]
  properties: {
    originGroup: {
      id: frontDoorOriginGroup.id
    }
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
  }
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

output webAppHostName string = webApp.properties.defaultHostName
output frontDoorEndpointHostName string = frontDoorEndpoint.properties.hostName		
