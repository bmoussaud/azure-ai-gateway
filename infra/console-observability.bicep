param environmentName string
param logsName string

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' existing = { name: environmentName }
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: logsName }
resource httpLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'workshop-http-ingress'
  scope: environment
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'ContainerAppHTTPLogs', enabled: true }
      { category: 'ContainerAppConsoleLogs', enabled: true }
      { category: 'ContainerAppSystemLogs', enabled: true }
    ]
  }
}
