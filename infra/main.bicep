targetScope = 'resourceGroup'

@description('Azure region for both Foundry resources.')
param location string = resourceGroup().location

@description('Model version available to the subscription in the selected region.')
param modelVersion string = '2026-09-22'

@description('Capacity per deployment, in thousands of tokens per minute.')
@minValue(1)
param modelCapacity int = 10

var accountPrefix = 'foundry-${uniqueString(resourceGroup().id)}'

module project1 './project.bicep' = {
  name: 'project-1'
  params: {
    accountName: '${accountPrefix}-1'
    projectName: 'project-1'
    location: location
    modelVersion: modelVersion
    modelCapacity: modelCapacity
  }
}

module project2 './project.bicep' = {
  name: 'project-2'
  params: {
    accountName: '${accountPrefix}-2'
    projectName: 'project-2'
    location: location
    modelVersion: modelVersion
    modelCapacity: modelCapacity
  }
}

output projects object = {
  'project-1': project1.outputs.project
  'project-2': project2.outputs.project
}
