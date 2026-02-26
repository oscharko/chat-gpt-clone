// Chat Demo – Azure Infrastructure (Bicep)
// Resources: ACR, AI Foundry Account/Project/Deployment, ACA Environment + App, RBAC

targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = 'swedencentral'

@description('Unique suffix for globally unique names')
param uniqueSuffix string = substring(uniqueString(resourceGroup().id), 0, 8)

// ─── Names ───────────────────────────────────────────────────────────────────
var acrName = 'chatdemoacr${uniqueSuffix}'
var foundryName = 'chatdemoai${uniqueSuffix}'
var projectName = 'chatdemoproj'
var deploymentName = 'gpt41mini'
var acaEnvName = 'chatdemo-env'
var acaAppName = 'chatdemoapp'
var logWorkspaceName = 'chatdemo-logs-${uniqueSuffix}'

// ─── RBAC Role Definition IDs ────────────────────────────────────────────────
var openAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
var azureAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

// ─── Log Analytics (required for ACA Environment) ────────────────────────────
resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logWorkspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ─── Container Registry ──────────────────────────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

// ─── AI Foundry Account ──────────────────────────────────────────────────────
resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  identity: { type: 'SystemAssigned' }
  sku: { name: 'S0' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    publicNetworkAccess: 'Enabled'
  }
}

// ─── AI Foundry Project ──────────────────────────────────────────────────────
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: projectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Chat Demo Project'
    description: 'Project for chat demo with gpt-4.1-mini'
  }
}

// ─── Model Deployment ────────────────────────────────────────────────────────
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: deploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1-mini'
    }
  }
}

// ─── ACA Environment ─────────────────────────────────────────────────────────
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logWorkspace.properties.customerId
        sharedKey: logWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

// ─── ACA App ─────────────────────────────────────────────────────────────────
resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: acaAppName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'chatdemo'
          image: '${acr.properties.loginServer}/chatdemo:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'FOUNDRY_ENDPOINT', value: 'https://${foundryName}.services.ai.azure.com/api/projects/${projectName}' }
            { name: 'FOUNDRY_RESOURCE_NAME', value: foundryName }
            { name: 'DEPLOYMENT_NAME', value: deploymentName }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 2
      }
    }
  }
}

// ─── RBAC: ACA → ACR Pull ────────────────────────────────────────────────────
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, app.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── RBAC: ACA → Foundry (OpenAI User) ──────────────────────────────────────
resource openAiUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, app.id, openAiUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: openAiUserRoleId
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── RBAC: ACA → Foundry (Azure AI User) ────────────────────────────────────
resource azureAiUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, app.id, azureAiUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: azureAiUserRoleId
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────
output acrLoginServer string = acr.properties.loginServer
output appFqdn string = app.properties.configuration.ingress.fqdn
output appUrl string = 'https://${app.properties.configuration.ingress.fqdn}'
output foundryEndpoint string = 'https://${foundryName}.services.ai.azure.com/api/projects/${projectName}'
