@description('The name of the function app that you wish to create.')
param appName string
param appPurpose string
@description('Storage Account type')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
])
param storageAccountType string = 'Standard_LRS'

@description('Location for all resources.')
param location string

@description('Tags.')
param tags object

param linuxFxVersion string = 'Python|3.12'

param appSettings array = []

param networkIsolation bool = false
param identityId string
param principalId string
param clientId string

@description('The language worker runtime to load in the function app.')
param runtime string = 'python'
param aoaiEndpoint string
param storageAccountName string
param appConfigName string
param hostingPlanName string
param applicationInsightsName string
param virtualNetworkSubnetId string
param funcStorageName string
@description('Maximum instance count for Flex Consumption plan. Default: 100')
param maximumInstanceCount int = 100
@description('Instance memory in MB for Flex Consumption plan. Allowed: 2048, 4096. Default: 2048')
@allowed([2048, 4096])
param instanceMemoryMB int = 2048
@description('Whether the hosting plan is Flex Consumption. Affects function app configuration.')
param isFlexConsumption bool = true
var functionAppName = appName
var functionWorkerRuntime = runtime

// Map runtime to functionAppConfig runtime name
// Flex Consumption supports: python, node, dotnet-isolated, java, powerShell
var runtimeName = runtime == 'python' ? 'python' : (runtime == 'node' ? 'node' : (runtime == 'dotnet' ? 'dotnet-isolated' : runtime))

// RJ_Flex_consumption_CR1: Start: 11/05/2025 : Added for Flex Consumption deployment storage blob endpoint
// Construct blob endpoint URL for deployment storage (required for Flex Consumption validation)
// Note: For zipDeploy, deployment.storage is not actually used, but Azure requires it to be valid if present
var deploymentStorageBlobEndpoint = 'https://${funcStorageName}.blob.${environment().suffixes.storage}/deployment'
// RJ_Flex_consumption_CR1: End: 11/05/2025 : Added for Flex Consumption deployment storage blob endpoint

var openaiApiVersion = '2024-05-01-preview'
var openaiApiBase = aoaiEndpoint
var openaiModel = 'gpt-4o'

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' existing = {
  name: hostingPlanName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  tags: tags
  properties: {
    serverFarmId: hostingPlan.id
    publicNetworkAccess: 'Enabled'  //this stays enabled even if network isolation is set to true
    virtualNetworkSubnetId: networkIsolation ? virtualNetworkSubnetId : null
    siteConfig: {
      cors: {allowedOrigins: ['https://ms.portal.azure.com', 'https://portal.azure.com'] }
      // RJ_Flex_consumption_CR6: 11/05/2025 : Added for conditional alwaysOn setting - not supported for Flex Consumption plans
      alwaysOn: isFlexConsumption ? null : true
      publicNetworkAccess: networkIsolation ? null : 'Enabled'
      ipSecurityRestrictionsDefaultAction : networkIsolation ? 'Deny' : 'Allow'
      ipSecurityRestrictions: networkIsolation ? [
        {
          ipAddress: 'AzureCloud'
          tag: 'ServiceTag'
          action: 'Allow'
          priority: 100
          name: 'AllowAzureCloud'
          headers: {
          }
        }
      ] : null
      appSettings: concat(appSettings, [
        {
          name: 'AZURE_CLIENT_ID'
          value: clientId
        }
        {
          name: 'AZURE_TENANT_ID'
          value: subscription().tenantId
        }
        {
          name:'allow_environment_variables'
          value: 'true'
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: clientId
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: funcStorageName
        }
        {
          name: 'DataStorage__clientId'
          value: clientId
        }
        {
          name: 'DataStorage__accountName'
          value: storageAccountName
        }
        {
          name: 'DataStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: applicationInsights.properties.InstrumentationKey
        }
        {
          name: 'ApplicationInsights__InstrumentationKey'
          value: applicationInsights.properties.InstrumentationKey
        }
        // RJ_Flex_consumption_CR2: Start: 11/05/2025 : Added for conditional FUNCTIONS_WORKER_RUNTIME setting
        // FUNCTIONS_WORKER_RUNTIME is not allowed for Flex Consumption plans
        // Runtime is configured via functionAppConfig.runtime instead
      ], isFlexConsumption ? [] : [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: functionWorkerRuntime
        }
      ], isFlexConsumption ? [] : [
        // RJ_Flex_consumption_CR2: End: 11/05/2025 : Added for conditional FUNCTIONS_WORKER_RUNTIME setting
        // RJ_Flex_consumption_CR3: Start: 11/05/2025 : Added for conditional ENABLE_ORYX_BUILD and SCM_DO_BUILD_DURING_DEPLOYMENT settings
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        // RJ_Flex_consumption_CR3: End: 11/05/2025 : Added for conditional ENABLE_ORYX_BUILD and SCM_DO_BUILD_DURING_DEPLOYMENT settings
      ], [
        {
          name: 'APP_CONFIGURATION_URI'
          value: concat('https://', appConfigName, '.azconfig.io')
        }
        networkIsolation ? {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: '1'
        } : {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: '0'
        }
        networkIsolation ? {
          name: 'WEBSITE_DNS_SERVER'
          value: '168.63.129.16'
        } : {
          name: 'WEBSITE_DNS_SERVER'
          value: ''
        }
        {
          name: 'WEBSITE_HTTPLOGGING_RETENTION_DAYS'
          value: '7'
        }
      ], appPurpose == 'processing' ? [
        {
          name: 'AzureWebJobsFeatureFlags'
          value: 'EnableWorkerIndexing'
        }
      ] : [])
      ftpsState: 'FtpsOnly'
      // RJ_Flex_consumption_CR4: 11/05/2025 : Added for conditional linuxFxVersion setting - not allowed for Flex Consumption plans, must be set via functionAppConfig.runtime instead
      linuxFxVersion: isFlexConsumption ? null : linuxFxVersion
      minTlsVersion: '1.2'
    }
    // RJ_Flex_consumption_CR5: Start: 11/05/2025 : Added for Flex Consumption functionAppConfig with runtime, scaling, and deployment configuration
    // Flex Consumption plan requires functionAppConfig
    // Note: deployment.storage is optional for zipDeploy, but Azure requires it to be valid if present
    // We provide a minimal valid configuration to satisfy validation
    functionAppConfig: isFlexConsumption ? {
      runtime: {
        name: runtimeName
        version: runtime == 'python' ? '3.11' : (runtime == 'node' ? '20' : '~4')
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      // deployment.storage is required for validation even with zipDeploy
      deployment: {
        storage: {
          type: 'blobContainer'
          value: deploymentStorageBlobEndpoint
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identityId
          }
        }
      }
    } : null
    // RJ_Flex_consumption_CR5: End: 11/05/2025 : Added for Flex Consumption functionAppConfig with runtime, scaling, and deployment configuration
    httpsOnly: true
  }
}

resource authConfig 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'authsettingsV2' 
  properties: {
    globalValidation: {
      requireAuthentication: false  // ✅ Disables authentication (allows anonymous access)
    }
    platform: {
      enabled: false  // ✅ Ensures platform authentication is disabled
    }
  }
}

output id string = functionApp.id
output name string = functionApp.name
output uri string = 'https://${functionApp.properties.defaultHostName}'
output identityPrincipalId string = principalId
output location string = functionApp.location
output funcStorageName string = funcStorageName
output openaiApiVersion string = openaiApiVersion
output openaiApiBase string = openaiApiBase
output openaiModel string = openaiModel
output functionWorkerRuntime string = functionWorkerRuntime
output hostingPlanName string = hostingPlan.name
output hostingPlanId string = hostingPlan.id
