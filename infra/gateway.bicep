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

// Same versioned definitions are read by the CLI and the console, never applied during a run.
var baseline = loadJsonContent('../config/profiles/baseline.json')
var scenarios = [
  baseline
  union(baseline, { alias: 'demo-alt' })
  loadJsonContent('../config/profiles/weighted-routing.json')
  loadJsonContent('../config/profiles/failover.json')
  loadJsonContent('../config/profiles/token-quota.json')
  loadJsonContent('../config/profiles/token-rate.json')
  loadJsonContent('../config/profiles/identity-routing.json')
]

#disable-next-line BCP081
resource faultProvider 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2026-11-01' = {
  parent: workspace
  name: 'backend-fault'
  properties: {
    modelProviderType: 'Foundry'
    displayName: 'Permanent simulated bad route - failover only'
    foundry: {
      endpoint: {
        url: uri(projects[0].endpoint, 'demo-injected-unavailable/')
      }
      resourceIds: [projects[0].accountId]
    }
    authentication: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
  dependsOn: [backendRoles]
}

#disable-next-line BCP081
resource unavailable 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2026-11-01' = {
  name: '${gatewayName}/default/backend-fault/demo-unavailable'
  properties: {
    displayName: 'Permanent simulated fault - failover scenario only'
    deployment: {
      resourceId: projects[0].deploymentId
      modelName: projects[0].deploymentName
      modelVersion: projects[0].modelVersion
    }
    supportedEndpoints: ['/openai/v1/chat/completions']
    endpoints: [{
      api: 'v1/chat/completions'
      path: '/openai/v1/chat/completions'
    }]
    policies: []
  }
  dependsOn: [faultProvider]
}

#disable-next-line BCP081
resource aliases 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2026-11-01' = [for scenario in scenarios: {
  parent: workspace
  name: scenario.alias
  properties: {
    aliasName: scenario.alias
    backendModels: map(scenario.backends, (target, i) => union({
      resourceId: resourceId('Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models', gatewayName, 'default', target.?provider ?? 'backend-${i + 1}', target.?model ?? 'demo-model')
      priority: scenario.alias == 'demo-alt' ? 1 - i : target.priority
      weight: target.weight
    }, contains(target, 'when') ? {
      when: replace(target.when, '__TEAM_B_ENTRA_IDENTITY__', '${toLower(tenant().tenantId)}:${toLower(teamObjectIds[1])}')
    } : {}))
    selectionOrder: ['priority']
    failures: scenario.failures
    policies: scenario.policies
    ...(length(scenario.failures) > 0 ? {maxRetryAttempts: scenario.maxRetryAttempts} : {})
  }
  dependsOn: [models, unavailable]
}]

resource teamRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for index in range(0, length(scenarios) * length(teamObjectIds)): {
  scope: aliases[index % length(scenarios)]
  name: guid(aliases[index % length(scenarios)].id, teamObjectIds[index / length(scenarios)], 'models-user')
  properties: {
    principalId: teamObjectIds[index / length(scenarios)]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a6b68e3d-a1f0-4c60-8678-237c050cf4ea')
  }
}]

output id string = gateway.id
output principalId string = gateway.identity.principalId
output hostname string = gateway.properties.frontend.defaultHostname
