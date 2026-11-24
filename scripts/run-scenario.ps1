#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','identity-routing','token-rate','token-quota','cost-limit')][string]$Scenario,
    [ValidateRange(1,10)][int]$Samples = 10,
    [switch]$WorkshopRouting,
    [switch]$IdentityBackendFault,
    # The demo-alt alias stays deployed; its calls are opt-in CLI checks (both backends, no quota bypass by alias).
    [switch]$IncludeAlternateAlias,
    [string]$BaselineEvidencePath,
    [string]$EventPath,
    [string]$ActivityPath,
    [string]$StopPath,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot) '.demo')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
function Write-Activity([string]$Kind, [hashtable]$Fields = @{}) {
    if ($ActivityPath) {
        $entry = @{kind=$Kind; at=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0)} + $Fields
        $entry | ConvertTo-Json -Compress -Depth 10 | Add-Content -LiteralPath $ActivityPath -Encoding utf8
    }
}
Write-Activity 'checking-limits'
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$ids = Get-DemoIds $config
$tokenA = Get-DemoToken A $config
$tokenB = Get-DemoToken B $config
$endpoint = Get-DemoRuntimeEndpoint $state
if ($IdentityBackendFault -or $IncludeAlternateAlias) { throw 'Fixed scenarios never mutate endpoints or call a different alias.' }
if ($Scenario -eq 'cost-limit') { throw 'Cost remains disabled: native price_missing=true has not been resolved.' }
if ($WorkshopRouting) {
    if ($Scenario -ne 'weighted-routing' -or $PSBoundParameters.ContainsKey('Samples')) {
        throw 'Workshop routing is a fixed ten-call weighted demonstration.'
    }
}
$requests = switch ($Scenario) { baseline { 2 } weighted-routing { $Samples } failover { 4 } default { 10 } }
$attempts = if ($Scenario -eq 'failover') { 2 } else { 1 }
$estimate = Assert-DemoRunBudget $config $requests $attempts
$delaySeconds = 0
foreach ($project in $state.projects.Values) {
    $deployment = Get-DemoArm $project.deploymentId '2025-06-01'
    $limits = @($deployment.properties.rateLimits | Where-Object key -in @('request','token'))
    if (-not @($limits | Where-Object key -eq 'request').Count) { throw 'The real backend request-rate limit must be known before traffic.' }
    foreach ($limit in $limits) {
        if ($limit.count -le 0 -or $limit.renewalPeriod -le 0) { throw 'Invalid live backend rate limit.' }
        # Failover's permanent invalid path cannot consume model tokens. Each backend gets at most one send.
        $units = if ($limit.key -eq 'token') { 1088 } else { 1 }
        $delaySeconds = [Math]::Max($delaySeconds, [Math]::Ceiling($units * $limit.renewalPeriod / $limit.count))
    }
    if ($delaySeconds -gt 2) {
        throw "Backend capacity requires $delaySeconds seconds between sends. Increase backend capacity before running the two-second workshop demo."
    }
}
if ($Scenario -eq 'cost-limit') {
    Assert-DemoPricing $config $state $BaselineEvidencePath
}
$runId = [guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resultPath = Join-Path $OutputDirectory "$runId.json"
$results = [Collections.Generic.List[object]]::new()
$restorationFailures = [Collections.Generic.List[string]]::new()
$outcome = 'incomplete'
$pacing = [Diagnostics.Stopwatch]::new()
$baselineBefore = Get-DemoArmEnvelope "$($ids.workspace)/aliases/demo-chat"
$configurationUnchanged = $false
$alias = ''

function Assert-ScenarioActive {
    if ($StopPath -and (Test-Path -LiteralPath $StopPath)) {
        throw [OperationCanceledException]::new('Operator requested a stop.')
    }
}

function Wait-Scenario([int]$Milliseconds) {
    if (-not $StopPath) { Start-Sleep -Milliseconds $Milliseconds; return }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $Milliseconds) {
        Assert-ScenarioActive
        Start-Sleep -Milliseconds ([Math]::Clamp($Milliseconds - $timer.ElapsedMilliseconds, 1, 250))
    }
}

function Send-ScenarioCall([string]$Team, [string]$Alias, [string]$Phase) {
    Assert-ScenarioActive
    if ($results.Count -ge $requests) { throw 'Hard request ceiling reached; do not send more traffic.' }
    $remaining = $delaySeconds - $pacing.Elapsed.TotalSeconds
    if ($results.Count -and $remaining -gt 0) {
        Write-Activity 'pacing' @{team=$Team; seconds=[int][Math]::Ceiling($remaining)}
        Wait-Scenario ([int][Math]::Ceiling(1000 * $remaining))
    }
    $token = if ($Team -eq 'A') { $tokenA } else { $tokenB }
    $markers = if ($Team -eq 'A' -and $Scenario -eq 'token-rate') { 640 } elseif ($Team -eq 'A' -and $Scenario -eq 'token-quota') { 160 } else { 0 }
    $call = @{team=$Team; alias=$Alias; phase=$Phase; number=$results.Count + 1}
    Assert-ScenarioActive
    Write-Activity 'sending' $call
    $pacing.Restart()
    $r = Invoke-DemoRequest $endpoint $Alias $token $Team $Phase -SyntheticInputMarkers $markers
    $results.Add($r)
    if ($EventPath) { $r | ConvertTo-Json -Depth 15 -Compress | Add-Content -LiteralPath $EventPath }
    Write-Activity 'responded' ($call + @{status=$r.status})
    Write-Host ("{0} {1} {2} HTTP {3} {4:N0}ms trace={5}" -f $Phase,$Team,$Alias,$r.status,$r.latencyMs,$r.traceId)
    return $r
}

function Assert-Completion($Result) {
    if (-not $Result.completion) { throw "Expected a real completion; HTTP $($Result.status), trace $($Result.traceId)." }
}

try {
    Assert-ScenarioActive
    Write-Activity 'model-selected' @{config=(Get-DemoProfileSummary $config $Scenario)}
    $alias = Assert-DemoFixedScenario $config $Scenario
    Write-Activity 'model-verified' @{alias=$alias}
    switch ($Scenario) {
        baseline {
            foreach ($team in @('A','B')) {
                Assert-Completion (Send-ScenarioCall $team $alias 'healthy')
            }
        }
        weighted-routing {
            for ($i=0; $i -lt $requests; $i++) { Assert-Completion (Send-ScenarioCall 'A' $alias 'weighted') }
        }
        identity-routing {
            for ($i=0; $i -lt 5; $i++) {
                foreach ($team in @('A','B')) { Assert-Completion (Send-ScenarioCall $team $alias 'identity-healthy') }
            }
        }
        failover {
            foreach ($team in @('A','B','A','B')) {
                Assert-Completion (Send-ScenarioCall $team $alias 'permanent-failover')
            }
        }
        { $_ -in @('token-rate','token-quota','cost-limit') } {
            # Fixed counters survive launches and Stop. A may already be exhausted on a replay.
            $initial = Send-ScenarioCall 'A' $alias 'initial-A'
            if ($initial.status -lt 400) { Assert-Completion $initial }
            Assert-Completion (Send-ScenarioCall 'B' $alias 'initial-B')
            $rejected = $initial.status -ge 400
            for ($i=0; $i -lt 6; $i++) {
                if ($rejected) { break }
                $r = Send-ScenarioCall 'A' $alias 'consume-A'
                if ($r.status -ge 400) { $rejected=$true; break }
                Assert-Completion $r
            }
            if (-not $rejected) { throw 'Inconclusive: no rejection within the bounded allowance test. Do not increase traffic automatically.' }
            $retry = Send-ScenarioCall 'A' $alias 'still-rejected'
            if ($retry.status -lt 400) { throw 'Allowance was renewed or not yet consistently enforced.' }
            Assert-Completion (Send-ScenarioCall 'B' $alias 'B-continues')
        }
    }
    $outcome = 'http-observed-awaiting-native-telemetry'
} catch [OperationCanceledException] {
    if (-not $StopPath -or -not (Test-Path -LiteralPath $StopPath)) { throw }
    $outcome = 'stopped-by-operator'
} finally {
    try {
        $baselineAfter = Get-DemoArmEnvelope "$($ids.workspace)/aliases/demo-chat"
        $configurationUnchanged = $baselineBefore.etag -ceq $baselineAfter.etag -and
            (Test-DemoSubset $baselineBefore.body $baselineAfter.body) -and (Test-DemoSubset $baselineAfter.body $baselineBefore.body)
        if (-not $configurationUnchanged) { throw 'demo-chat changed during a read-only scenario.' }
        Write-Activity 'configuration-unchanged'
    }
    catch { $restorationFailures.Add("Fixed configuration verification failed: $($_.Exception.Message)") }
    @{
        runId=$runId; scenario=$Scenario; gatewayId=$state.gatewayId; outcome=$outcome
        startedBy='PowerShell lab runner'; concurrency=1; clientRetries=0
        conservativeTokenCostEstimateUsd=$estimate; requestCeiling=$requests
        minimumInterRequestSpacingSeconds=$delaySeconds
        workshopRouting=[bool]$WorkshopRouting
        alias=$alias; configurationMode='fixed-alias'; configurationUnchanged=$configurationUnchanged
        baselineEtagBefore=$baselineBefore.etag
        baselineEtagAfter=$(if ($configurationUnchanged) { $baselineAfter.etag } else { '' })
        identityBackendFault=$false
        restorationFailures=@($restorationFailures); results=@($results.ToArray())
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath
    Write-Host "HTTP observations saved: $resultPath. Not a native gateway proof until verify-results.ps1 succeeds."
    if ($restorationFailures.Count) { throw ($restorationFailures -join "`n") }
}
