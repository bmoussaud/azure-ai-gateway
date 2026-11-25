param prefix string
param location string
param gatewayName string
param logsName string
param operatorIpv4 string
param teamAIdentityId string
param teamBIdentityId string
param demoConfig string
param demoState string
param deployApp bool = false
param image string = ''
@allowed(['ip', 'entra'])
param authMode string = 'ip'
param authTenantId string = ''
param authClientId string = ''
param authUserPrincipalId string = ''
@secure()
param authClientSecret string = ''
param releaseIpRestriction bool = false

var tags = {
  purpose: 'ai-gateway-demo'
  managedBy: 'azure-ai-gateway-demo'
  demoGateway: gatewayName
}
#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' existing = { name: gatewayName }
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: logsName }
resource operator 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-console'
  location: location
  tags: tags
}
module callerMonitoring './console-monitoring.bicep' = {
  name: 'console-caller-monitoring'
  dependsOn: [operator]
  params: {
    prefix: prefix
    insightsName: '${prefix}-insights'
  }
}
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'aigw${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}
resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, operator.id, 'pull')
  scope: registry
  properties: {
    principalId: operator.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}
resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, operator.id, 'read-demo')
  properties: {
    principalId: operator.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}
resource logReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logs.id, operator.id, 'read-native')
  scope: logs
  properties: {
    principalId: operator.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
  }
}
module scenarioRole './console-role.bicep' = {
  name: 'console-read-only-role'
  params: { prefix: prefix }
}
resource scenarioGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(gateway.id, operator.id, 'scenario-operator')
  scope: gateway
  properties: {
    principalId: operator.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: scenarioRole.outputs.id
  }
}
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-console-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
  }
}
module ingressLogs './console-observability.bicep' = {
  name: 'console-ingress-observability'
  params: {
    environmentName: environment.name
    logsName: logs.name
  }
}
resource app 'Microsoft.App/containerApps@2024-03-01' = if (deployApp) {
  name: '${prefix}-console'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${operator.id}': {}
      '${teamAIdentityId}': {}
      '${teamBIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: authMode == 'entra' ? [{ name: 'console-auth-client-secret', value: authClientSecret }] : []
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
        ipSecurityRestrictions: authMode == 'entra' && releaseIpRestriction ? [] : [{
          name: 'workshop-operator'
          description: 'Only the current operator public IPv4 may access inference and scenario controls.'
          ipAddressRange: '${operatorIpv4}/32'
          action: 'Allow'
        }]
      }
      registries: [{ server: registry.properties.loginServer, identity: operator.id }]
    }
    template: {
      containers: [{
        name: 'console'
        image: image
        env: [
          { name: 'OPERATOR_CLIENT_ID', value: operator.properties.clientId }
          { name: 'DEMO_CONFIG_JSON', value: demoConfig }
          { name: 'DEMO_STATE_JSON', value: demoState }
          { name: 'DEMO_AUTH_MODE', value: authMode }
          { name: 'CONSOLE_AUTH_RESOURCE', value: authMode == 'entra' ? 'api://${authClientId}' : '' }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: callerMonitoring.outputs.connectionString
          }
        ]
        resources: { cpu: json('0.5'), memory: '1Gi' }
        probes: [
          {
            type: 'Liveness'
            httpGet: { path: '/health', port: 8080 }
            initialDelaySeconds: 10
            periodSeconds: 30
          }
          {
            type: 'Readiness'
            httpGet: { path: '/health', port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 10
          }
        ]
      }]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [pull, scenarioGrant, reader, logReader]
}
module authentication './console-auth.bicep' = if (deployApp && authMode == 'entra') {
  name: 'console-entra-authentication'
  params: {
    appName: app!.name
    tenantId: authTenantId
    clientId: authClientId
    userPrincipalId: authUserPrincipalId
    operatorPrincipalId: operator.properties.principalId
    operatorClientId: operator.properties.clientId
    consoleOrigin: 'https://${prefix}-console.${environment.properties.defaultDomain}'
  }
}
output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output operatorClientId string = operator.properties.clientId
output operatorPrincipalId string = operator.properties.principalId
output environmentId string = environment.id
output appName string = '${prefix}-console'
output url string = deployApp ? 'https://${app!.properties.configuration.ingress.fqdn}' : ''
