#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$ResultsPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$run = Get-Content -LiteralPath $ResultsPath -Raw | ConvertFrom-Json -AsHashtable
if ($run.gatewayId -ine $state.gatewayId -or $run.outcome -ne 'http-observed-awaiting-native-telemetry') {
    throw 'Only complete HTTP observations from this gateway can be checked.'
}
$query = Get-DemoRequestsQuery $state
$traceIds = @($run.results | ForEach-Object { if ($_.traceId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid trace ID.' }; "'$($_.traceId)'" })
$query += "`n| where TraceId in ($($traceIds -join ','))"
$rows = @(Invoke-DemoQuery $config $state $query)
if ($rows.Count -ne $run.results.Count) { throw 'Inconclusive: missing/duplicate native request spans. Allow ingestion delay, then rerun verification without sending more traffic.' }
$native = @{}
foreach ($row in $rows) { $native[[string]$row.TraceId] = $row }
$primary = 'backend-1/demo-model'
$secondary = 'backend-2/demo-model'
foreach ($result in $run.results) {
    $row = $native[$result.traceId]
    $identity = if ($result.team -eq 'A') { $config.teamAObjectId } else { $config.teamBObjectId }
    if ($row.Identity -ine $identity -or [int]$row.HttpStatus -ne $result.status) {
        throw 'Native identity/status does not match the HTTP observation.'
    }
    if ($result.completion -and ($row.StatusCode -eq 'Error' -or $row.Backend -notin @($primary,$secondary))) {
        throw 'Completion has no healthy native serving backend evidence.'
    }
    if ($run.scenario -eq 'baseline') {
        $expectedBackend = if ($result.alias -eq 'demo-chat') { $primary } else { $secondary }
        if ($row.Backend -ine $expectedBackend) { throw 'Baseline did not prove both intended real backends.' }
    }
    if ($run.scenario -eq 'failover') {
        if ($result.phase -in @('primary','recovered') -and $row.Backend -ine $primary) { throw 'Primary selection/recovery not observed.' }
        if ($result.phase -in @('secondary','failover','excluded','recovered-secondary') -and $row.Backend -ine $secondary) { throw 'Secondary selection not observed.' }
        if ($result.phase -eq 'failover' -and [int]$row.Attempts -ne 2) { throw 'Native failover did not show two backend sends.' }
        if ($result.phase -eq 'excluded' -and [int]$row.Attempts -ne 1) { throw 'Temporary exclusion not observed.' }
    }
    if ($run.scenario -in @('token-rate','token-quota','cost-limit') -and $result.status -ge 400) {
        $expectedPolicy = if ($run.scenario -eq 'cost-limit') { 'costLimit' } else { 'tokenLimit' }
        if ($row.RejectedPolicy -ne $expectedPolicy) { throw "Inconclusive: rejection is not attributed to the intended native $expectedPolicy policy." }
    }
}
if ($run.scenario -eq 'weighted-routing') {
    $n = $rows.Count
    $primaryCount = @($rows | Where-Object Backend -IEQ $primary).Count
    if ($run['workshopRouting']) {
        if ($n -ne 10 -or $run.minimumInterRequestSpacingSeconds -gt 2 -or
            @($run.results | Where-Object { -not $_.completion -or $_.status -ne 200 }).Count) {
            throw 'Expected 10 completed workshop calls with at most two seconds of intentional spacing.'
        }
        Write-Host "Observed native primary selections: $primaryCount/$n. This sample does not certify the configured weights."
    } else {
        $tolerance = Assert-DemoWeightedDistribution $primaryCount $n
        Write-Host "Observed native primary distribution: $primaryCount/$n; 80/20 tolerance +/- $tolerance."
    }
}
if ($run.scenario -eq 'identity-routing') {
    Assert-DemoIdentityRouting $run $rows
    foreach ($team in @('A','B')) {
        $traces = @($run.results | Where-Object team -CEQ $team | ForEach-Object traceId)
        $backends = @($rows | Where-Object TraceId -CIn $traces | Group-Object Backend | ForEach-Object { "$($_.Name)=$($_.Count)" })
        Write-Host "Native identity routing $team : $($backends -join ', ')."
    }
}
$evidencePath = [IO.Path]::ChangeExtension($ResultsPath, 'verified.json')
@{ runId=$run.runId; scenario=$run.scenario; gatewayId=$state.gatewayId; verifiedAt=[DateTimeOffset]::UtcNow.ToString('o')
    source='Native OTelSpans and OTelLogs; not client telemetry'; rows=$rows } |
    ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $evidencePath
Write-Host "Native scenario evidence verified: $evidencePath"
