param prefix string
param insightsName string

resource insights 'Microsoft.Insights/components@2020-02-02-preview' existing = { name: insightsName }
resource operator 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: '${prefix}-console'
}
// Standard Azure Monitor exporter authenticates at the Insights component, not its managed RG.
resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, operator.id, 'console-caller-traces')
  scope: insights
  properties: {
    principalId: operator.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}
@secure()
output connectionString string = insights.properties.ConnectionString
output operatorClientId string = operator.properties.clientId
