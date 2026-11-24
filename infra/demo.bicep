targetScope = 'subscription'

@description('Explicit dedicated resource group. Never point this template at a shared group.')
param resourceGroupName string
param location string
param secondaryLocation string = location
param monitoringLocation string = location
@minLength(3)
@maxLength(24)
param gatewayName string
@allowed([
  'Standard'
  'Premium'
  'Consumption'
])
param gatewaySku string
param modelName string
param modelVersion string
param deploymentName string = modelName
param modelSku string = 'GlobalStandard'
@minValue(1)
param modelCapacity int = 1
@description('Object IDs of two distinct existing Entra workload identities, not application client IDs.')
param teamAObjectId string
param teamBObjectId string
@description('Optional Cost Management alert recipients. Empty disables the budget.')
param budgetEmails array = []
@minValue(1)
param monthlyBudget int = 20
param budgetStart string = utcNow('yyyy-MM-01')

var tags = {
  purpose: 'ai-gateway-demo'
  managedBy: 'azure-ai-gateway-demo'
  demoGateway: gatewayName
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module backends './main.bicep' = {
  scope: group
  name: 'demo-backends'
  params: {
    location: location
    secondaryLocation: secondaryLocation
    modelName: modelName
    modelVersion: modelVersion
    deploymentName: deploymentName
    modelSku: modelSku
    modelCapacity: modelCapacity
  }
}

module gateway './gateway.bicep' = {
  scope: group
  name: 'demo-gateway'
  params: {
    gatewayName: gatewayName
    location: location
    gatewaySku: gatewaySku
    tags: tags
    projects: [
      backends.outputs.projects['project-1']
      backends.outputs.projects['project-2']
    ]
    teamObjectIds: [teamAObjectId, teamBObjectId]
  }
}

module monitoring './monitoring.bicep' = {
  scope: group
  name: 'demo-monitoring'
  params: {
    location: monitoringLocation
    prefix: gatewayName
    gatewayName: gatewayName
    gatewayPrincipalId: gateway.outputs.principalId
    tags: tags
  }
}

module budget './budget.bicep' = if (!empty(budgetEmails)) {
  scope: group
  name: 'demo-budget'
  params: {
    amount: monthlyBudget
    emails: budgetEmails
    start: '${budgetStart}T00:00:00Z'
  }
}

output demo object = {
  resourceGroupId: group.id
  gatewayId: gateway.outputs.id
  hostname: gateway.outputs.hostname
  workspaceId: '${gateway.outputs.id}/workspaces/default'
  logAnalyticsId: monitoring.outputs.workspaceId
  logAnalyticsCustomerId: monitoring.outputs.workspaceCustomerId
  workbookName: monitoring.outputs.workbookName
  insightsId: monitoring.outputs.insightsId
  metricsId: monitoring.outputs.metricsId
  teamAObjectId: teamAObjectId
  teamBObjectId: teamBObjectId
  projects: backends.outputs.projects
}
