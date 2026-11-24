#requires -Version 7.4
param([string]$ConfigPath, [string]$EventsPath, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$events = @(Get-Content -LiteralPath $EventsPath | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
if (-not $events.Count) { return }
$traces = @($events | ForEach-Object {
    if ($_.traceId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid console trace ID.' }
    "'$($_.traceId)'"
})
$query = Get-DemoRequestsQuery $state
$query += "`n| where TraceId in ($($traces -join ','))"
$rows = @(Invoke-DemoQuery $config $state $query)
ConvertTo-Json -InputObject $rows -Depth 20 | Set-Content -LiteralPath $OutputPath
