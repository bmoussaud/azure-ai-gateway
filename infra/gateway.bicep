param gatewayName string
param location string
param gatewaySku string
param tags object
param projects array
param teamObjectIds array

// The pinned public OpenAPI defines these types; older Bicep type bundles do not.
#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' = {
  name: gatewayName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: gatewaySku
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

#disable-next-line BCP081
resource workspace 'Microsoft.ApiManagement/aigateways/workspaces@2026-11-01' existing = {
  parent: gateway
  name: 'default'
}

module backendRoles './backend-role.bicep' = [for (project, i) in projects: {
  name: 'gateway-backend-role-${i}'
  params: {
    accountName: last(split(project.accountId, '/'))
    principalId: gateway.identity.principalId
  }
}]

#disable-next-line BCP081
resource providers 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2026-11-01' = [for (project, i) in projects: {
  parent: workspace
  name: 'backend-${i + 1}'
  properties: {
    modelProviderType: 'Foundry'
    displayName: 'Demo backend ${i + 1}'
    foundry: {
      endpoint: {
        url: project.endpoint
      }
      resourceIds: [project.accountId]
    }
    authentication: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
  dependsOn: [backendRoles]
}]

#disable-next-line BCP081
resource models 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2026-11-01' = [for (project, i) in projects: {
  name: '${gatewayName}/default/backend-${i + 1}/demo-model'
  properties: {
    displayName: 'Demo model ${i + 1}'
    deployment: {
      resourceId: project.deploymentId
      modelName: project.deploymentName
      modelVersion: project.modelVersion
    }
    supportedEndpoints: ['/openai/v1/chat/completions']
    endpoints: [{
      api: 'v1/chat/completions'
      path: '/openai/v1/chat/completions'
    }]
    policies: []
  }
  dependsOn: [providers]
}]

var aliasNames = ['demo-chat', 'demo-alt']

#disable-next-line BCP081
resource aliases 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2026-11-01' = [for alias in aliasNames: {
  parent: workspace
  name: alias
  properties: {
    aliasName: alias
    backendModels: [for (project, i) in projects: {
      resourceId: resourceId('Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models', gatewayName, 'default', 'backend-${i + 1}', 'demo-model')
      priority: i
      weight: 1
    }]
    selectionOrder: ['priority']
    maxRetryAttempts: 0
    failures: []
    policies: []
  }
  dependsOn: [models]
}]

resource teamRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for binding in [
  { team: 0, alias: 0 }
  { team: 0, alias: 1 }
  { team: 1, alias: 0 }
  { team: 1, alias: 1 }
]: {
  scope: aliases[binding.alias]
  name: guid(aliases[binding.alias].id, teamObjectIds[binding.team], 'models-user')
  properties: {
    principalId: teamObjectIds[binding.team]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a6b68e3d-a1f0-4c60-8678-237c050cf4ea')
  }
}]

output id string = gateway.id
output principalId string = gateway.identity.principalId
output hostname string = gateway.properties.frontend.defaultHostname
