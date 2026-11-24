#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$allowed = @($state.gatewayId, $state.logAnalyticsId)
$allowed += "$($state.resourceGroupId)/providers/Microsoft.ContainerInstance/containerGroups/$($config.gatewayName)-runner"
if ($state.ContainsKey('callerIdentities')) {
    foreach ($identity in $state.callerIdentities.Values) { $allowed += $identity.id }
}
foreach ($project in $state.projects.Values) { $allowed += @($project.accountId,$project.id,$project.deploymentId) }
$base = "$($state.resourceGroupId)/providers"
$allowed += @(
    "$base/Microsoft.Monitor/accounts/$($config.gatewayName)-metrics",
    "$base/Microsoft.Insights/components/$($config.gatewayName)-insights",
    "$base/Microsoft.Insights/dataCollectionEndpoints/$($config.gatewayName)-otlp",
    "$base/Microsoft.Insights/dataCollectionRules/$($config.gatewayName)-otlp",
    "$base/Microsoft.Insights/workbooks/$($state.workbookName)"
)
$console = @(Invoke-DemoAz @('deployment','group','list','--subscription',$config.subscriptionId,
    '--resource-group',$config.resourceGroupName,'--query',"[?name=='$($config.gatewayName)-console']"))
if ($console.Count) {
    $consoleDeployment = Invoke-DemoAz @('deployment','group','show','--subscription',$config.subscriptionId,
        '--resource-group',$config.resourceGroupName,'--name',"$($config.gatewayName)-console")
    $registryName = $consoleDeployment.properties.outputs.registryName.value
    if ($registryName -cnotmatch '^aigw[a-z0-9]{13}$') { throw 'Unexpected console registry output; cleanup refused.' }
    $allowed += @(
        "$base/Microsoft.ContainerRegistry/registries/$registryName",
        "$base/Microsoft.App/managedEnvironments/$($config.gatewayName)-console-env",
        "$base/Microsoft.App/containerApps/$($config.gatewayName)-console",
        "$base/Microsoft.ManagedIdentity/userAssignedIdentities/$($config.gatewayName)-console"
    )
}
$resources = @(Invoke-DemoAz @('resource','list','--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroupName))
$generatedRuleId = "$base/Microsoft.AlertsManagement/smartDetectorAlertRules/Failure Anomalies - $($config.gatewayName)-insights"
if (@($resources | Where-Object id -IEQ $generatedRuleId).Count) {
    $rule = Get-DemoArm $generatedRuleId '2021-04-01'
    $insightsId = "$base/Microsoft.Insights/components/$($config.gatewayName)-insights"
    if ($rule.properties.detector.id -ne 'FailureAnomaliesDetector' -or
        $rule.properties.scope.Count -ne 1 -or $rule.properties.scope[0] -ine $insightsId) {
        throw 'Auto-generated alert is not scoped exclusively to the demo component. Cleanup refused.'
    }
    $allowed += $generatedRuleId
}
$unknown = @($resources | Where-Object { $_.id -notin $allowed })
if ($unknown.Count) { throw "Group contains $($unknown.Count) unexpected resource(s). Cleanup refused; inspect the dedicated group." }
if ($PSCmdlet.ShouldProcess($state.resourceGroupId, 'Delete dedicated demo resource group and all its resources')) {
    $null = Invoke-DemoAz @('group','delete','--subscription',$config.subscriptionId,'--name',$config.resourceGroupName,'--yes')
    if (Invoke-DemoAz @('group','exists','--subscription',$config.subscriptionId,'--name',$config.resourceGroupName)) {
        throw 'Resource group deletion has not completed.'
    }
    Write-Host 'Dedicated demo group deleted. No directory principals or unrelated subscription resources were removed.'
}
