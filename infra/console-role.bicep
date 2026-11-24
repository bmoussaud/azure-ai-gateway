param prefix string

resource scenarioRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'console-scenario-operator')
  properties: {
    roleName: '${prefix} bounded scenario operator'
    description: 'Read fixed scenario definitions only. No configuration writes, inference or IAM permissions.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: [
        'Microsoft.ApiManagement/aigateways/read'
        'Microsoft.ApiManagement/aigateways/workspaces/read'
        'Microsoft.ApiManagement/aigateways/workspaces/aliases/read'
        'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/read'
        'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models/read'
      ]
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}

output id string = scenarioRole.id
