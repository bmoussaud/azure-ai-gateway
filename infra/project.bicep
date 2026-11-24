param accountName string
param projectName string
param location string
param modelVersion string
param modelCapacity int
param modelName string = 'gpt-6-sol'
param deploymentName string = modelName
param modelSku string = 'GlobalStandard'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
  }
}

resource model 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: deploymentName
  sku: {
    name: modelSku
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
  // Foundry rejects concurrent project/deployment writes on the parent account.
  dependsOn: [project]
}

output project object = {
  id: project.id
  accountId: account.id
  endpoint: account.properties.endpoint
  deploymentName: model.name
  deploymentId: model.id
  modelName: modelName
  modelVersion: modelVersion
  location: location
}
