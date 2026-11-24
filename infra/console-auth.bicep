param appName string
param tenantId string
param clientId string
param userPrincipalId string
param operatorPrincipalId string
param operatorClientId string
param consoleOrigin string

resource app 'Microsoft.App/containerApps@2024-03-01' existing = { name: appName }
resource authentication 'Microsoft.App/containerApps/authConfigs@2024-03-01' = {
  parent: app
  name: 'current'
  properties: {
    platform: { enabled: true }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
      excludedPaths: ['/health']
    }
    httpSettings: { requireHttps: true }
    login: {
      allowedExternalRedirectUrls: [consoleOrigin]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: clientId
          clientSecretSettingName: 'console-auth-client-secret'
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        login: { loginParameters: ['scope=openid profile email'] }
        validation: {
          allowedAudiences: [clientId, 'api://${clientId}']
          defaultAuthorizationPolicy: {
            allowedApplications: [clientId, operatorClientId]
            allowedPrincipals: { identities: [userPrincipalId, operatorPrincipalId] }
          }
        }
      }
    }
  }
}
