targetScope = 'resourceGroup'

@description('Azure region for both Foundry resources.')
param location string = resourceGroup().location

@description('Model version available to the subscription in the selected region.')
param modelVersion string = '2026-09-22'

@description('Capacity per deployment, in thousands of tokens per minute.')
@minValue(1)
param modelCapacity int = 10

param modelName string = 'gpt-6-sol'
param deploymentName string = modelName
param modelSku string = 'GlobalStandard'
param secondaryLocation string = location

var accountPrefix = 'foundry-${uniqueString(resourceGroup().id)}'

module project1 './project.bicep' = {
  name: 'project-1'
  params: {
    accountName: '${accountPrefix}-1'
    projectName: 'project-1'
    location: location
    modelVersion: modelVersion
    modelCapacity: modelCapacity
    modelName: modelName
    deploymentName: deploymentName
    modelSku: modelSku
  }
}

module project2 './project.bicep' = {
  name: 'project-2'
  params: {
    accountName: '${accountPrefix}-2'
    projectName: 'project-2'
    location: secondaryLocation
    modelVersion: modelVersion
    modelCapacity: modelCapacity
    modelName: modelName
    deploymentName: deploymentName
    modelSku: modelSku
  }
}

output projects object = {
  'project-1': project1.outputs.project
  'project-2': project2.outputs.project
}
