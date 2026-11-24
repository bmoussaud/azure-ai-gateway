param prefix string
param location string
param teamAIdentityId string
param teamBIdentityId string

resource runner 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${prefix}-runner'
  location: location
  tags: {
    purpose: 'ai-gateway-demo'
    managedBy: 'azure-ai-gateway-demo'
    demoGateway: prefix
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${teamAIdentityId}': {}
      '${teamBIdentityId}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Never'
    containers: [{
      name: 'runner'
      properties: {
        image: 'mcr.microsoft.com/azure-cli@sha256:123feca19aa2b702a9abfe7d82e89452308bde429c49bce9e54648f9834a1e11'
        command: ['/bin/sh', '-c', 'sleep 14400']
        resources: {
          requests: {
            cpu: 1
            memoryInGB: 1
          }
        }
      }
    }]
  }
}

output id string = runner.id
