targetScope = 'subscription'

/*
** AI Infrastructure
** Copyright (C) 2023 Microsoft, Inc.
** All Rights Reserved
**
***************************************************************************
*/

import { DeploymentSettings } from '../types/DeploymentSettings.bicep'
import { DiagnosticSettings } from '../types/DiagnosticSettings.bicep'
import { PrivateEndpointSettings } from '../types/PrivateEndpointSettings.bicep'

// ========================================================================
// PARAMETERS
// ========================================================================

@description('The deployment settings to use for this deployment.')
param deploymentSettings DeploymentSettings

@description('The resource names for the resources to be created.')
param resourceNames object

@description('The diagnostic settings to use for logging and metrics.')
param diagnosticSettings DiagnosticSettings

@description('If true, use a common App Service Plan.  If false, use a separate App Service Plan per App Service.')
param useCommonAppServicePlan bool

@description('The model version of ChatGpt to deploy. Must align with version supported by region.')
param chatGptDeploymentVersion string = ''

@description('The model version of text-embedding-3 to deploy. Must align with version supported by region.')
param embeddingDeploymentVersion string = ''

/*
** Dependencies
*/

@description('The list of subnets that are used for linking into the virtual network if using network isolation.')
param subnets object = {}

@description('When deploying a hub, the private endpoints will need this parameter to specify the resource group that holds the Private DNS zones')
param dnsResourceGroupName string = ''

@description('The managed identity name to use as the identity of the App Service.')
param managedIdentityName string

@description('The ID of the Log Analytics workspace to use for diagnostics and logging.')
param logAnalyticsWorkspaceId string = ''

@description('The ID of the Application Insights resource to use for App Service logging.')
param applicationInsightsId string = ''

param searchIndexName string

@description('The name of the storage account to use for PDF files related to RAG.')
param storageAccountName string
param aiStorageContainerName string = 'content'

/*
** Settings
*/

@allowed([
  'disabled'
  'free'
  'standard'
])
param searchServiceSemanticRankerLevel string = 'standard'

@description('The service prefix to use.')
param servicePrefix string

@description('The IP address of the current system.  This is used to set up the firewall for Key Vault and SQL Server if in development mode.')
param clientIpAddress string = ''

@allowed([ 'None', 'AzureServices' ])
@description('If allowedIp is set, whether azure services are allowed to bypass the storage and AI services firewall.')
param bypass string = 'AzureServices'

@description('The pricing and capacity SKU for the Cognitive Services deployment')
param openAiSkuName string = 'S0'

@allowed([ 'free', 'basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2' ])
param searchServiceSkuName string = 'standard'

// ========================================================================
// VARIABLES
// ========================================================================

var searchQueryLanguage = 'en-us' // only supporting known defaults in this version
var searchQuerySpeller = 'lexicon' // only supporting known defaults in this version

var useSpeechInputBrowser = false // not supported in this version
var useSpeechOutputBrowser = false // not supported in this version
var useSpeechOutputAzure = false // not supported in this version
var gpt4vModelName = 'gpt-4o'

// The tags to apply to all resources in this workload
var moduleTags = union(deploymentSettings.tags, deploymentSettings.workloadTags)

var isAzureOpenAiHost = true
var deployAzureOpenAi = true

var chatGpt = {
  modelName: 'gpt-4o'
  deploymentName: 'chat'
  deploymentVersion: !empty(chatGptDeploymentVersion) ? chatGptDeploymentVersion : '2024-05-13'
  deploymentCapacity: 10
}

var embedding = {
  modelName: 'text-embedding-3-large'
  deploymentName: 'embedding'
  deploymentCapacity: 120
  deploymentVersion: !empty(embeddingDeploymentVersion) ? embeddingDeploymentVersion : '1'
  dimensions: 3072
}

var openAiDeployments = [
  {
    name: chatGpt.deploymentName
    model: {
      format: 'OpenAI'
      name: chatGpt.modelName
      version: chatGpt.deploymentVersion
    }
    sku: {
      name: 'GlobalStandard' //found that the SKU was 'GlobalStandard' instead of 'Standard' for Azure region uksouth, need further research in how tightly to control this param '
      capacity: chatGpt.deploymentCapacity
    }
  }
  {
    name: embedding.deploymentName
    model: {
      format: 'OpenAI'
      name: embedding.modelName
      version: embedding.deploymentVersion
    }
    sku: {
      name: 'Standard'
      capacity: embedding.deploymentCapacity
    }
  }
]

var actualSearchServiceSemanticRankerLevel = (searchServiceSkuName == 'free') ? 'disabled' : searchServiceSemanticRankerLevel

// ========================================================================
// EXISTING RESOURCES
// ========================================================================

var applicationInsights = reference(applicationInsightsId, '2020-02-02')

resource resourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' existing = {
  name: resourceNames.resourceGroup
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: resourceGroup
  name: managedIdentityName
}

// ========================================================================
// NEW RESOURCES
// ========================================================================

module openAi '../core/ai/cognitiveservices.bicep' = if (isAzureOpenAiHost && deployAzureOpenAi) {
  name: 'openai-${deploymentSettings.resourceToken}'
  scope: resourceGroup
  params: {
    name: resourceNames.appCognitiveServices // '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: resourceGroup.location
    tags: moduleTags
    publicNetworkAccess: deploymentSettings.isNetworkIsolated ? 'Disabled' : 'Enabled'
    bypass: bypass // defaults to alow AzureServices
    sku: {
      name: openAiSkuName
    }
    clientIpAddress: clientIpAddress
    deployments: openAiDeployments
    disableLocalAuth: true
    privateEndpointSettings: deploymentSettings.isNetworkIsolated ? {
      dnsResourceGroupName: dnsResourceGroupName
      name: resourceNames.cogServicesPrivateEndpoint
      resourceGroupName: resourceNames.spokeResourceGroup
      subnetId: subnets[resourceNames.spokePrivateEndpointSubnet].id
    } : null
  }
}

// Create an App Service Plan to group applications under the same payment plan and SKU
module appServicePlan '../core/hosting/app-service-plan.bicep' = {
  name: '${servicePrefix}-app-plan-${deploymentSettings.resourceToken}'
  scope: resourceGroup
  params: {
    name: resourceNames.pyAppServicePlan //'${abbrs.webServerFarms}${resourceToken}'
    location: resourceGroup.location
    tags: moduleTags
    serverType: 'Linux'

    // Dependencies
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    
    sku: deploymentSettings.isProduction ? 'P1v3' : 'B1'
    zoneRedundant: deploymentSettings.isProduction
  }
}


module appService '../core/hosting/app-service.bicep' = {
  name: '${servicePrefix}-app-${deploymentSettings.resourceToken}'
  scope: resourceGroup
  params: {
    name: resourceNames.pyAppService
    location: resourceGroup.location
    tags: moduleTags

    // intended settings from sample
    /*
    alwaysOn: appServiceSkuName != 'F1' // default is true
    managedIdentity: true // using UAMI
    virtualNetworkSubnetId: isolation.outputs.appSubnetId // handled elsewhere

    // Entra ID settings
    clientAppId: clientAppId
    serverAppId: serverAppId
    clientSecretSettingName: !empty(clientAppSecret) ? 'AZURE_CLIENT_APP_SECRET' : ''
    authenticationIssuerUri: authenticationIssuerUri
    use32BitWorkerProcess: appServiceSkuName == 'F1'
    
    // setting is part of Easy Auth
    enableUnauthenticatedAccess: enableUnauthenticatedAccess
    */
    siteConfig: {
      linuxFxVersion: 'python|3.11'
      appCommandLine: 'entrypoint.sh'//'python3 -m gunicorn main:app'
    }

    // Dependencies
    appServicePlanName: useCommonAppServicePlan ? resourceNames.commonAppServicePlan : appServicePlan.outputs.name
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    managedIdentityId: managedIdentity.id
    outboundSubnetId: deploymentSettings.isNetworkIsolated ? subnets[resourceNames.spokeWebOutboundSubnet].id : '' // same as .NET API

    // Settings
    appSettings: {
      APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.ConnectionString // APPLICATIONINSIGHTS_CONNECTION_STRING: useApplicationInsights ? monitoring.outputs.applicationInsightsConnectionString : ''
      // APPLICATIONINSIGHTS_INSTRUMENTATIONKEY: applicationInsights.InstrumentationKey

      SCM_DO_BUILD_DURING_DEPLOYMENT: string(true)
      ENABLE_ORYX_BUILD: string(true)
      PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true' 

      AZURE_SEARCH_INDEX: searchIndexName
      AZURE_SEARCH_SERVICE: searchService.outputs.name
      AZURE_SEARCH_SEMANTIC_RANKER: actualSearchServiceSemanticRankerLevel
      AZURE_VISION_ENDPOINT: '' // AZURE_VISION_ENDPOINT: useGPT4V ? computerVision.outputs.endpoint : ''
      AZURE_SPEECH_SERVICE_ID: '' // AZURE_SPEECH_SERVICE_ID: useSpeechOutputAzure ? speech.outputs.id : ''
      AZURE_SPEECH_SERVICE_LOCATION: '' //AZURE_SPEECH_SERVICE_LOCATION: useSpeechOutputAzure ? speech.outputs.location : ''
      USE_SPEECH_INPUT_BROWSER: useSpeechInputBrowser
      USE_SPEECH_OUTPUT_BROWSER: useSpeechOutputBrowser
      USE_SPEECH_OUTPUT_AZURE: useSpeechOutputAzure
      
      AZURE_STORAGE_ACCOUNT: storageAccountName
      AZURE_STORAGE_CONTAINER: aiStorageContainerName
      AZURE_SEARCH_QUERY_LANGUAGE: searchQueryLanguage
      AZURE_SEARCH_QUERY_SPELLER: searchQuerySpeller
      
      // Shared by all OpenAI deployments
      OPENAI_HOST: 'openai' //openAiHost
      AZURE_OPENAI_EMB_MODEL_NAME: embedding.modelName
      AZURE_OPENAI_EMB_DIMENSIONS: embedding.dimensions
      AZURE_OPENAI_CHATGPT_MODEL: chatGpt.modelName
      AZURE_OPENAI_GPT4V_MODEL: gpt4vModelName

      // Specific to Azure OpenAI
      AZURE_OPENAI_SERVICE: isAzureOpenAiHost && deployAzureOpenAi ? openAi.outputs.name : ''
      AZURE_OPENAI_CHATGPT_DEPLOYMENT: chatGpt.deploymentName
      AZURE_OPENAI_EMB_DEPLOYMENT: embedding.deploymentName

      AZURE_OPENAI_GPT4V_DEPLOYMENT: '' // useGPT4V ? gpt4vDeploymentName : ''

      AZURE_OPENAI_API_VERSION: '' //azureOpenAiApiVersion
      AZURE_OPENAI_API_KEY: '' //azureOpenAiApiKey
      AZURE_OPENAI_CUSTOM_URL: '' //azureOpenAiCustomUrl
    }
    diagnosticSettings: diagnosticSettings
    enablePublicNetworkAccess: !deploymentSettings.isNetworkIsolated
    privateEndpointSettings: deploymentSettings.isNetworkIsolated ? {
      dnsResourceGroupName: dnsResourceGroupName
      name: resourceNames.webAppPyPrivateEndpoint
      resourceGroupName: resourceNames.spokeResourceGroup
      subnetId: subnets[resourceNames.spokeWebInboundSubnet].id
    } : null
    servicePrefix: servicePrefix
  }
}

// =====================================================================================================================
//     AZURE AI Search
// =====================================================================================================================

module searchService '../core/search/search-services.bicep' = {
  name: 'search-service-${deploymentSettings.resourceToken}'
  scope: resourceGroup
  params: {
    name: resourceNames.searchService
    location: resourceGroup.location
    tags: moduleTags
    disableLocalAuth: true
    sku: {
      name: searchServiceSkuName
    }
    semanticSearch: actualSearchServiceSemanticRankerLevel
    publicNetworkAccess: deploymentSettings.isNetworkIsolated ?  'disabled' : 'enabled'
    sharedPrivateLinkStorageAccounts: [] // does not link to storage accounts
    
    privateEndpointSettings: deploymentSettings.isNetworkIsolated ? {
      dnsResourceGroupName: dnsResourceGroupName
      name: resourceNames.searchPrivateEndpoint
      resourceGroupName: resourceNames.spokeResourceGroup
      subnetId: subnets[resourceNames.spokePrivateEndpointSubnet].id
    } : null
  }
}

module searchDiagnostics '../core/search/search-diagnostics.bicep' = {
  name: 'search-diagnostics-${deploymentSettings.resourceToken}'
  scope: resourceGroup
  params: {
    searchServiceName: searchService.outputs.name
    workspaceId: logAnalyticsWorkspaceId // there may be an option to monitor with App Insights to explore
  }
}


// =====================================================================================================================
//     RBAC - todo move these so that the grants are specific to resources instead of subscription
// =====================================================================================================================
// full list of built-in azure roles
// https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles



// Perform RBAC for Azure AI Search
// Grants read access to Azure AI Search index data.
var searchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

resource roleGrantUAMIAccessToReadSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup.id, 'GiveUAMIPermissionToAccessSearch' , searchIndexDataReader)
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReader)
  }
}

resource roleGrantCurrentUserAccessToReadSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup.id, deploymentSettings.principalId , searchIndexDataReader)
  properties: {
    principalId: deploymentSettings.principalId
    principalType: deploymentSettings.principalType
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReader)
  }
}

// Lets you manage Search services, but not access to them.
var searchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
resource roleGrantCurrentUserAccessToManageSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup.id, 'GiveUAMIPermissionManageSearchServices', searchServiceContributor)
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributor)
  }
}

// Grants full access to Azure Cognitive Search index data.
var searchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
resource roleGrantUAMIAccessToCreateSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup.id, 'GiveUAMIPermissionToUploadDocsAndGenerateAISearchData', searchIndexDataContributor)
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
  }
}
resource roleGrantCurrentUserAccessToCreateSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup.id, deploymentSettings.principalId, searchIndexDataContributor)
  properties: {
    principalId: deploymentSettings.principalId
    principalType: deploymentSettings.principalType
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
  }
}

// module ownerManagedIdentityRoleAssignment '../core/identity/resource-group-role-assignment.bicep' = {
//   name: 'owner-managed-identity-role-assignment-${deploymentSettings.resourceToken}'
//   scope: resourceGroup
//   params: {
//     identityName: resourceNames.ownerManagedIdentity
//     roleId: searchIndexDataContributor
//     roleDescription: 'Grant the "Contributor" role to the user-assigned managed identity so it can run deployment scripts.'
//   }
// }
