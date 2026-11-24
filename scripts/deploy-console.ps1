#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [string]$OperatorIpv4)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$runtimeConfig = $config.Clone()
Write-Host 'Reading the dedicated demo target and managed caller outputs...'
$state = Get-DemoState $config
if (-not $state.callersProvisioned) { throw 'Console requires the two dedicated managed caller identities.' }
if (-not $OperatorIpv4) { $OperatorIpv4 = (Invoke-RestMethod 'https://api4.ipify.org' -TimeoutSec 10).Trim() }
$ip = $null
if (-not [Net.IPAddress]::TryParse($OperatorIpv4, [ref]$ip) -or
    $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $ip.Equals([Net.IPAddress]::Any) -or [Net.IPAddress]::IsLoopback($ip)) {
    throw 'Supply a single valid public operator IPv4; unrestricted ingress is forbidden.'
}
$file = [IO.Path]::GetTempFileName()
$root = Split-Path $PSScriptRoot
$parameters = @{
    prefix=@{value=$config.gatewayName}; location=@{value=$config.location}; gatewayName=@{value=$config.gatewayName}
    logsName=@{value=($state.logAnalyticsId -split '/')[-1]}; operatorIpv4=@{value=$OperatorIpv4}
    teamAIdentityId=@{value=$state.callerIdentities.A.id}; teamBIdentityId=@{value=$state.callerIdentities.B.id}
    demoConfig=@{value=($runtimeConfig | ConvertTo-Json -Depth 15 -Compress)}
    demoState=@{value=($state | ConvertTo-Json -Depth 15 -Compress)}
}
try {
    $common = @('--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroupName,
        '--name',"$($config.gatewayName)-console",'--template-file',(Join-Path $root 'infra\console.bicep'),
        '--parameters',"@$file")
    @{parameters=$parameters} | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $file
    Write-Host 'Validating and provisioning console registry, identity and environment...'
    $null = Invoke-DemoAz (@('deployment','group','validate') + $common)
    $null = Invoke-DemoAz (@('deployment','group','what-if','--no-pretty-print') + $common)
    $deployment = Invoke-DemoAz (@('deployment','group','create') + $common)
    $registry = $deployment.properties.outputs.registryName.value
    $tag = "console:$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
    Write-Host 'Building the server image in the dedicated Azure Container Registry...'
    $null = Invoke-DemoAz @('acr','build','--subscription',$config.subscriptionId,'--registry',$registry,
        '--image',$tag,'--file',(Join-Path $root 'console\Dockerfile'),'--no-logs',$root)
    $digest = Invoke-DemoAz @('acr','repository','show','--subscription',$config.subscriptionId,'--name',$registry,
        '--image',$tag,'--query','digest')
    if ($digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Registry returned no immutable image digest.' }
    $parameters.deployApp = @{value=$true}
    $parameters.image = @{value="$($deployment.properties.outputs.registryServer.value)/console@$digest"}
    Write-Host 'Validating the console behind the bootstrap IPv4 /32 guard...'
    @{parameters=$parameters} | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $file
    $null = Invoke-DemoAz (@('deployment','group','validate') + $common)
    $null = Invoke-DemoAz (@('deployment','group','what-if','--no-pretty-print') + $common)
    $previous = Invoke-DemoAz @('containerapp','list','--subscription',$config.subscriptionId,
        '--resource-group',$config.resourceGroupName,'--query',"[?name=='$($config.gatewayName)-console']")
    if (@($previous).Count) {
        $maintenance = & az containerapp exec --subscription $config.subscriptionId `
            --resource-group $config.resourceGroupName --name "$($config.gatewayName)-console" `
            --command 'python3 /app/console/operate.py maintenance' --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0 -or ($maintenance -join "`n") -notmatch 'MAINTENANCE_READY') {
            throw 'Privileged maintenance was not confirmed; deployment refused.'
        }
    }
    $live = Invoke-DemoAz (@('deployment','group','create') + $common)
    $url = $live.properties.outputs.url.value
    if (-not $url) { throw 'Container App returned no HTTPS URL.' }
    @{url=$url; appName=$live.properties.outputs.appName.value; image=$parameters.image.value;
        access='operator IPv4 /32 only'; deployedAt=[DateTimeOffset]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $root '.demo\console-deployment.json')
    & (Join-Path $PSScriptRoot 'enable-console-auth.ps1') -ConfigPath $ConfigPath
} finally { Remove-Item -LiteralPath $file -Force }
