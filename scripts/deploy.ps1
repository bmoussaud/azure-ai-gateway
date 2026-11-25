#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$Apply)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
& (Join-Path $PSScriptRoot 'preflight.ps1') -ConfigPath $ConfigPath
$exists = Invoke-DemoAz @('group','exists','--subscription',$config.subscriptionId,'--name',$config.resourceGroupName)
if ($exists) { Assert-DemoGroup $config }
$parameters = @{}
foreach ($key in @('resourceGroupName','location','secondaryLocation','monitoringLocation','gatewayName','gatewaySku',
    'modelName','modelVersion','deploymentName','modelSku','modelCapacity','teamAObjectId','teamBObjectId','provisionDemoCallers','budgetEmails','monthlyBudget')) {
    if ($config.ContainsKey($key)) { $parameters[$key] = @{ value = $config[$key] } }
}
$file = [IO.Path]::GetTempFileName()
try {
    @{ '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
       contentVersion='1.0.0.0'; parameters=$parameters } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $file
    $common = @('--subscription',$config.subscriptionId,'--location',$config.location,'--name',"demo-$($config.gatewayName)",
        '--template-file',(Join-Path (Split-Path $PSScriptRoot) 'infra\demo.bicep'),'--parameters',"@$file")
    $null = Invoke-DemoAz (@('deployment','sub','validate') + $common)
    $plan = Invoke-DemoAz (@('deployment','sub','what-if','--no-pretty-print') + $common)
    $plan | ConvertTo-Json -Depth 50 | Write-Host
    if (-not $Apply) { Write-Host 'Validation/what-if only. Use -Apply to provision the explicit dedicated target.'; return }
    $null = Invoke-DemoAz (@('deployment','sub','create') + $common)
    $state = Get-DemoState $config
    Set-DemoInsightsPublisher $config $state
    $gateway = Get-DemoArm $state.gatewayId
    if ($gateway.properties.provisioningState -ne 'Succeeded' -or -not $state.hostname) { throw 'Gateway is not ready.' }
    & (Join-Path $PSScriptRoot 'reset-demo.ps1') -ConfigPath $ConfigPath
    Write-Host 'Infrastructure and fixed scenario aliases read back. No live inference or telemetry validation has been claimed.'
} finally { Remove-Item -LiteralPath $file -Force }
