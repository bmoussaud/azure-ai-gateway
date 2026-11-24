#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$allowed = @($state.gatewayId, $state.logAnalyticsId)
foreach ($project in $state.projects.Values) { $allowed += @($project.accountId,$project.id,$project.deploymentId) }
$base = "$($state.resourceGroupId)/providers"
$allowed += @(
    "$base/Microsoft.Monitor/accounts/$($config.gatewayName)-metrics",
    "$base/Microsoft.Insights/components/$($config.gatewayName)-insights",
    "$base/Microsoft.Insights/dataCollectionEndpoints/$($config.gatewayName)-otlp",
    "$base/Microsoft.Insights/dataCollectionRules/$($config.gatewayName)-otlp",
    "$base/Microsoft.Insights/workbooks/$($state.workbookName)"
)
$resources = @(Invoke-DemoAz @('resource','list','--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroupName))
$unknown = @($resources | Where-Object { $_.id -notin $allowed })
if ($unknown.Count) { throw "Group contains $($unknown.Count) unexpected resource(s). Cleanup refused; inspect the dedicated group." }
if ($PSCmdlet.ShouldProcess($state.resourceGroupId, 'Delete dedicated demo resource group and all its resources')) {
    $null = Invoke-DemoAz @('group','delete','--subscription',$config.subscriptionId,'--name',$config.resourceGroupName,'--yes')
    if (Invoke-DemoAz @('group','exists','--subscription',$config.subscriptionId,'--name',$config.resourceGroupName)) {
        throw 'Resource group deletion has not completed.'
    }
    Write-Host 'Dedicated demo group deleted. No directory principals or unrelated subscription resources were removed.'
}
