#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$Offline)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$root = Split-Path $PSScriptRoot
$null = Get-Command az -ErrorAction Stop
$output = [IO.Path]::GetTempFileName()
try {
    & az bicep build --file (Join-Path $root 'infra\demo.bicep') --outfile $output --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
} finally { Remove-Item -LiteralPath $output -Force }
if ($Offline) {
    Write-Host 'Local configuration and Bicep compilation passed. Azure access, SKU, regions, quota and runtime are NOT verified.'
    return
}

$account = Invoke-DemoAz @('account','show','--subscription',$config.subscriptionId)
if ($account.id -ine $config.subscriptionId -or $account.state -ne 'Enabled') { throw 'Explicit subscription is not enabled/accessible.' }
$metadata = Invoke-DemoAz @('provider','show','--subscription',$config.subscriptionId,'--namespace','Microsoft.ApiManagement')
if ($metadata.registrationState -ne 'Registered') { throw 'Microsoft.ApiManagement must be registered by an authorized operator.' }
$gatewayType = @($metadata.resourceTypes | Where-Object resourceType -eq 'aigateways')
if ($gatewayType.Count -ne 1 -or $gatewayType[0].apiVersions -notcontains '2026-11-01') {
    throw 'The target subscription does not advertise the required stable AI Gateway API.'
}
$locations = (Get-DemoArm "/subscriptions/$($config.subscriptionId)/locations" '2022-12-01').value
$region = @($locations | Where-Object name -eq $config.location)
if ($region.Count -ne 1 -or $gatewayType[0].locations -notcontains $region[0].displayName) {
    throw 'The target subscription does not advertise AI Gateway in the selected region.'
}
foreach ($namespace in @('Microsoft.CognitiveServices','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Monitor')) {
    $provider = Invoke-DemoAz @('provider','show','--subscription',$config.subscriptionId,'--namespace',$namespace)
    if ($provider.registrationState -ne 'Registered') { throw "$namespace must be registered by an authorized operator." }
}

$regionCounts = @($config.location,$config.secondaryLocation) | Group-Object
foreach ($entry in $regionCounts) {
    $models = Invoke-DemoAz @('cognitiveservices','model','list','--subscription',$config.subscriptionId,'--location',$entry.Name)
    $matches = @($models | Where-Object { $_.model.name -ceq $config.modelName -and $_.model.version -ceq $config.modelVersion })
    $skus = @($matches | ForEach-Object { $_.model.skus } | Where-Object name -ceq $config.modelSku)
    if ($skus.Count -lt 1) { throw "Model/version/SKU not advertised in $($entry.Name). Do not deploy guessed values." }
    $usageNames = @($skus | ForEach-Object usageName | Select-Object -Unique)
    if ($usageNames.Count -ne 1 -or -not $usageNames[0]) { throw 'Ambiguous model quota mapping; inspect the catalog before deployment.' }
    $usages = Invoke-DemoAz @('cognitiveservices','usage','list','--subscription',$config.subscriptionId,'--location',$entry.Name)
    $quota = @($usages | Where-Object { $_.name.value -ceq $usageNames[0] })
    $required = $entry.Count * [int]$config.modelCapacity
    if ($quota.Count -ne 1 -or ($quota[0].limit - $quota[0].currentValue) -lt $required) {
        throw "Insufficient/unverifiable quota in $($entry.Name); need $required model capacity units."
    }
}
Write-Host 'Read-only discovery passed. Capacity is not reserved. Actual gateway SKU acceptance, OTLP and runtime still require ARM/live checks.'
