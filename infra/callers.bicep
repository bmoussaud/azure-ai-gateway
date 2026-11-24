param prefix string
param location string
param tags object

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for team in ['a', 'b']: {
  name: '${prefix}-team-${team}'
  location: location
  tags: tags
}]

output teams object = {
  A: {
    id: identities[0].id
    principalId: identities[0].properties.principalId
    clientId: identities[0].properties.clientId
  }
  B: {
    id: identities[1].id
    principalId: identities[1].properties.principalId
    clientId: identities[1].properties.clientId
  }
}
