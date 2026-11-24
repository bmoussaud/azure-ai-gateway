#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','token-rate','token-quota','cost-limit')][string]$Scenario,
    [ValidateRange(50,200)][int]$Samples = 100,
    [string]$BaselineEvidencePath,
    [string]$EventPath,
    [string]$ActivityPath,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot) '.demo')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
function Write-Activity([string]$Kind, [hashtable]$Fields = @{}) {
    if ($ActivityPath) {
        $entry = @{kind=$Kind; at=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0)} + $Fields
        $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $ActivityPath -Encoding utf8
    }
}
Write-Activity 'checking-limits'
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$ids = Get-DemoIds $config
$tokenA = Get-DemoToken A $config
$tokenB = Get-DemoToken B $config
$endpoint = Get-DemoRuntimeEndpoint $state
$requests = if ($Scenario -eq 'weighted-routing') { $Samples } elseif ($Scenario -eq 'failover') { 8 } else { 12 }
$attempts = if ($Scenario -eq 'failover') { 2 } else { 1 }
$estimate = Assert-DemoRunBudget $config $requests $attempts
$delaySeconds = 0
foreach ($project in $state.projects.Values) {
    $deployment = Get-DemoArm $project.deploymentId '2025-06-01'
    $limits = @($deployment.properties.rateLimits | Where-Object key -in @('request','token'))
    if (-not @($limits | Where-Object key -eq 'request').Count) { throw 'The real backend request-rate limit must be known before traffic.' }
    foreach ($limit in $limits) {
        if ($limit.count -le 0 -or $limit.renewalPeriod -le 0) { throw 'Invalid live backend rate limit.' }
        $units = if ($limit.key -eq 'token') { 1088 * $attempts } else { $attempts }
        $delaySeconds = [Math]::Max($delaySeconds, [Math]::Ceiling($units * $limit.renewalPeriod / $limit.count))
    }
}
if ($Scenario -eq 'cost-limit') {
    Assert-DemoPricing $config $state $BaselineEvidencePath
}
$runId = [guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resultPath = Join-Path $OutputDirectory "$runId.json"
$results = [Collections.Generic.List[object]]::new()
$savedModels = @{}
$restorationFailures = [Collections.Generic.List[string]]::new()
$outcome = 'incomplete'
$pacing = [Diagnostics.Stopwatch]::new()

function Send-ScenarioCall([string]$Team, [string]$Alias, [string]$Phase) {
    if ($results.Count -ge $requests) { throw 'Hard request ceiling reached; do not send more traffic.' }
    $remaining = $delaySeconds - $pacing.Elapsed.TotalSeconds
    if ($results.Count -and $remaining -gt 0) {
        Write-Activity 'pacing' @{team=$Team; seconds=[int][Math]::Ceiling($remaining)}
        Start-Sleep -Milliseconds ([int][Math]::Ceiling(1000 * $remaining))
    }
    $token = if ($Team -eq 'A') { $tokenA } else { $tokenB }
    $markers = if ($Team -eq 'A' -and $Scenario -eq 'token-rate') { 640 } elseif ($Team -eq 'A' -and $Scenario -eq 'token-quota') { 160 } else { 0 }
    $call = @{team=$Team; alias=$Alias; phase=$Phase; number=$results.Count + 1}
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

function Set-LabPathFault([int]$Backend) {
    $id = "$($ids.workspace)/modelProviders/backend-$Backend/models/demo-model"
    if (-not $savedModels.ContainsKey($id)) {
        $model = Get-DemoArm $id
        if (-not $model.properties.ContainsKey('endpoints') -or $model.properties.endpoints.Count -ne 1) {
            throw 'Lab fault requires an explicit single endpoint mapping so restoration is exact.'
        }
        $savedModels[$id] = @($model.properties.endpoints)
    }
    Write-Activity 'injecting' @{backend=$Backend}
    Set-DemoArmProperties $id @{ endpoints = @(@{ api='v1/chat/completions'; path='/demo-injected-unavailable' }) }
}

try {
    Write-Activity 'applying-profile'
    Set-DemoProfile $config $Scenario
    $second = [DateTimeOffset]::UtcNow.Second
    if ($Scenario -eq 'token-rate' -and $second -gt 5) {
        Write-Activity 'quota-window' @{seconds=61 - $second}
        Start-Sleep -Seconds (61 - $second)
    }
    switch ($Scenario) {
        baseline {
            foreach ($team in @('A','B')) {
                foreach ($alias in @('demo-chat','demo-alt')) { Assert-Completion (Send-ScenarioCall $team $alias 'healthy') }
            }
        }
        weighted-routing {
            for ($i=0; $i -lt $Samples; $i++) { Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'weighted') }
        }
        failover {
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'primary')
            Assert-Completion (Send-ScenarioCall 'B' 'demo-alt' 'secondary')
            Set-LabPathFault 1
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'failover')
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'excluded')
            Set-LabPathFault 2
            $failed = Send-ScenarioCall 'A' 'demo-chat' 'all-down'
            if ($failed.status -lt 400) { throw 'All-down must produce an explicit HTTP error.' }
            Write-Activity 'repairing-routes'
            foreach ($id in @($savedModels.Keys)) { Set-DemoArmProperties $id @{ endpoints=$savedModels[$id] } }
            Write-Activity 'recovery-window' @{seconds=35}
            Start-Sleep -Seconds 35
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'recovered')
            Assert-Completion (Send-ScenarioCall 'B' 'demo-alt' 'recovered-secondary')
        }
        { $_ -in @('token-rate','token-quota','cost-limit') } {
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'initial-A')
            Assert-Completion (Send-ScenarioCall 'B' 'demo-chat' 'initial-B')
            $rejected = $false
            for ($i=0; $i -lt 6; $i++) {
                $r = Send-ScenarioCall 'A' 'demo-chat' 'consume-A'
                if ($r.status -ge 400) { $rejected=$true; break }
                Assert-Completion $r
            }
            if (-not $rejected) { throw 'Inconclusive: no rejection within the bounded allowance test. Do not increase traffic automatically.' }
            $retry = Send-ScenarioCall 'A' 'demo-chat' 'still-rejected'
            if ($retry.status -lt 400) { throw 'Allowance was renewed or not yet consistently enforced.' }
            Assert-Completion (Send-ScenarioCall 'B' 'demo-chat' 'B-continues')
            $alternate = Send-ScenarioCall 'A' 'demo-alt' 'alternate-rejected'
            if ($alternate.status -lt 400) { throw 'Allowance was bypassed, renewed, or not yet consistently enforced.' }
            Assert-Completion (Send-ScenarioCall 'B' 'demo-alt' 'B-alternate')
        }
    }
    $outcome = 'http-observed-awaiting-native-telemetry'
} finally {
    # Failure to publish progress must never prevent restoration.
    try { Write-Activity 'restoring' } catch { Write-Warning 'Could not publish restoration progress.' }
    foreach ($id in @($savedModels.Keys)) {
        try { Set-DemoArmProperties $id @{ endpoints=$savedModels[$id] } }
        catch { $restorationFailures.Add("Failed to restore $id : $($_.Exception.Message)") }
    }
    try { Set-DemoProfile $config baseline }
    catch { $restorationFailures.Add("Failed to restore baseline: $($_.Exception.Message)") }
    @{
        runId=$runId; scenario=$Scenario; gatewayId=$state.gatewayId; outcome=$outcome
        startedBy='PowerShell lab runner'; concurrency=1; clientRetries=0
        conservativeTokenCostEstimateUsd=$estimate; requestCeiling=$requests
        minimumInterRequestSpacingSeconds=$delaySeconds
        restorationFailures=@($restorationFailures); results=@($results.ToArray())
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath
    Write-Host "HTTP observations saved: $resultPath. Not a native gateway proof until verify-results.ps1 succeeds."
    if ($restorationFailures.Count) { throw ($restorationFailures -join "`n") }
}
