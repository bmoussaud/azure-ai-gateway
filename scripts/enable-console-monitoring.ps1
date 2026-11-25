#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [string]$Image)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$insights = Get-DemoArm $state.insightsId '2020-02-02-preview'
if (-not $insights.properties.DisableLocalAuth -or -not $insights.properties.ConnectionString) {
    throw 'Entra-only Insights ingestion and a verified connection string must be enabled first.'
}
$name = "$($config.gatewayName)-console"
$before = Invoke-DemoAz @('containerapp','show','--subscription',$config.subscriptionId,
    '--resource-group',$config.resourceGroupName,'--name',$name)
if (-not $Image) { $Image = $before.properties.template.containers[0].image }
$expectedRegistry = $before.properties.configuration.registries[0].server
if ($Image -cnotmatch "^$([regex]::Escape($expectedRegistry))/console@sha256:[0-9a-f]{64}$") {
    throw 'Supply an immutable console image from the existing dedicated registry.'
}
$root = Split-Path $PSScriptRoot
$parameters = [IO.Path]::GetTempFileName()
try {
    @{parameters=@{prefix=@{value=$config.gatewayName}
        insightsName=@{value=($state.insightsId -split '/')[-1]}}} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $parameters
    $common = @('--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroupName,
        '--name',"$name-monitoring",'--template-file',(Join-Path $root 'infra\console-monitoring.bicep'),
        '--parameters',"@$parameters")
    $null = Invoke-DemoAz (@('deployment','group','validate') + $common)
    $null = Invoke-DemoAz (@('deployment','group','what-if','--no-pretty-print') + $common)
    $null = Invoke-DemoAz (@('deployment','group','create') + $common)
    $maintenance = & az containerapp exec `
        --subscription $config.subscriptionId --resource-group $config.resourceGroupName --name $name `
        --command 'python3 /app/console/operate.py maintenance' 2>&1
    if ($LASTEXITCODE -ne 0 -or ($maintenance -join "`n") -notmatch 'MAINTENANCE_READY') {
        throw 'Maintenance was not confirmed; no console image or settings changed.'
    }
    $null = Invoke-DemoAz @('containerapp','update','--subscription',$config.subscriptionId,
        '--resource-group',$config.resourceGroupName,'--name',$name,'--image',$Image,
        '--set-env-vars',"APPLICATIONINSIGHTS_CONNECTION_STRING=$($insights.properties.ConnectionString)")
    $after = Invoke-DemoAz @('containerapp','show','--subscription',$config.subscriptionId,
        '--resource-group',$config.resourceGroupName,'--name',$name)
    foreach ($property in @('ingress','registries','activeRevisionsMode')) {
        if (($before.properties.configuration[$property] | ConvertTo-Json -Depth 20 -Compress) -cne
            ($after.properties.configuration[$property] | ConvertTo-Json -Depth 20 -Compress)) {
            throw "Console $property changed unexpectedly; inspect access controls."
        }
    }
    if (($before.identity | ConvertTo-Json -Depth 10 -Compress) -cne
        ($after.identity | ConvertTo-Json -Depth 10 -Compress)) { throw 'Console identities changed unexpectedly.' }
    Write-Host 'OpenTelemetry caller monitoring configured with managed identity. Runtime ingestion still requires verification.'
} finally { Remove-Item -LiteralPath $parameters -Force }
