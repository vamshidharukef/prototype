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
        name: 'subnet-webapp'
        properties: {
          addressPrefix: vnetSubnetWebappPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          serviceEndpoints: [
            {
              service: 'Microsoft.Web'
              locations: [
                location
              ]
            }
          ]
        }
      }
      {
        name: 'subnet-privateendpoint'
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
      vnetRouteAllEnabled: true
      vnetName: webAppVnet.name           
    }     
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
  properties: {}
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
resource accessRestriction 'Microsoft.Web/sites/config@2021-02-01' = {
  parent: webApp
  name: 'web'
  properties: {
    publicNetworkAccess: 'Enabled'
    ipSecurityRestrictions: [
      {
        name: 'AllowVNet'
        priority: 100
        action: 'Allow'
        tag: 'Default'
        vnetSubnetResourceId: webAppVnet.properties.subnets[0].id
      }
      {
        name: 'AllowAzureFrontDoor'
        priority: 200
        action: 'Allow'
        ipAddress: allowIpRange        
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
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'
      probeIntervalInSeconds: 100
    }
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
          name: 'AllowVNet'
          priority: 1
          enabledState: 'Enabled'
          ruleType: 'MatchRule'
          action: 'Allow'
          matchConditions: [
            {
              matchVariable: 'RemoteAddr'
              operator: 'IPMatch'
              negateCondition: false
              matchValue: [
                vnetAddressPrefix
              ]
              transforms: []  
              
              
            }
          ]
        }
        {
          name: 'AllowAzureFrontDoor'
          priority: 2
          enabledState: 'Enabled'
          ruleType: 'MatchRule'
          action: 'Allow'
          matchConditions: [
            {
              matchVariable: 'RequestHeader'
              selector: 'X-Azure-FDID'
              operator: 'Contains'
              negateCondition: false
              matchValue: [
                frontDoorProfile.properties.frontDoorId
              ]
              transforms: []
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

output webAppHostName string = webApp.properties.defaultHostName
output frontDoorEndpointHostName string = frontDoorEndpoint.properties.hostName		
