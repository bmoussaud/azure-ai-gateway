#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','identity-routing','token-rate','token-quota','cost-limit')][string]$Scenario,
    [ValidateRange(50,200)][int]$Samples = 100,
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
if ($IdentityBackendFault -and $Scenario -ne 'identity-routing') {
    throw 'The hard-pin negative check applies only to identity routing.'
}
if ($WorkshopRouting) {
    if ($Scenario -ne 'weighted-routing' -or $PSBoundParameters.ContainsKey('Samples')) {
        throw 'Workshop routing is a fixed ten-call weighted demonstration.'
    }
}
$requests = if ($Scenario -eq 'weighted-routing') { $Samples } elseif ($Scenario -eq 'failover') { 8 } else { 12 }
if ($WorkshopRouting) { $requests = 10 }
if ($Scenario -eq 'identity-routing') { $requests = if ($IdentityBackendFault) { 4 } else { 10 } }
$attempts = if ($Scenario -eq 'failover') { 2 } else { 1 }
# Native traces showed a simulated fault takes about 6-11 s to reach the gateway data plane after ARM confirms it.
$faultPropagationSeconds = 20
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
    if (($WorkshopRouting -or $Scenario -eq 'identity-routing') -and $delaySeconds -gt 2) {
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
$savedModels = @{}
$restorationFailures = [Collections.Generic.List[string]]::new()
$outcome = 'incomplete'
$pacing = [Diagnostics.Stopwatch]::new()

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

function Set-LabPathFault([int]$Backend) {
    Assert-ScenarioActive
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
    Write-Activity 'fault-propagation' @{backend=$Backend; seconds=$faultPropagationSeconds}
    Wait-Scenario ($faultPropagationSeconds * 1000)
}

try {
    Assert-ScenarioActive
    Write-Activity 'applying-profile' @{config=(Get-DemoProfileSummary $config $Scenario)}
    Set-DemoProfile $config $Scenario
    Write-Activity 'profile-applied'
    $second = [DateTimeOffset]::UtcNow.Second
    if ($Scenario -eq 'token-rate' -and $second -gt 5) {
        Write-Activity 'quota-window' @{seconds=61 - $second}
        Wait-Scenario ((61 - $second) * 1000)
    }
    switch ($Scenario) {
        baseline {
            $aliases = if ($IncludeAlternateAlias) { @('demo-chat','demo-alt') } else { @('demo-chat') }
            foreach ($team in @('A','B')) {
                foreach ($alias in $aliases) { Assert-Completion (Send-ScenarioCall $team $alias 'healthy') }
            }
        }
        weighted-routing {
            for ($i=0; $i -lt $requests; $i++) { Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'weighted') }
        }
        identity-routing {
            if ($IdentityBackendFault) {
                Assert-Completion (Send-ScenarioCall 'B' 'demo-chat' 'identity-healthy')
                Set-LabPathFault 2
                $failed = Send-ScenarioCall 'B' 'demo-chat' 'pinned-unavailable'
                if ($failed.status -lt 400) { throw 'B must fail explicitly when its only eligible backend is down.' }
                Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'A-isolated')
                Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'A-isolated')
            } else {
                for ($i=0; $i -lt 5; $i++) {
                    foreach ($team in @('A','B')) { Assert-Completion (Send-ScenarioCall $team 'demo-chat' 'identity-healthy') }
                }
            }
        }
        failover {
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'primary')
            if ($IncludeAlternateAlias) { Assert-Completion (Send-ScenarioCall 'B' 'demo-alt' 'secondary') }
            Set-LabPathFault 1
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'failover')
            # Exclusion is a gateway-wide backend state, so team B also skips the failed backend.
            Assert-Completion (Send-ScenarioCall ($IncludeAlternateAlias ? 'A' : 'B') 'demo-chat' 'excluded')
            Set-LabPathFault 2
            $failed = Send-ScenarioCall 'A' 'demo-chat' 'all-down'
            if ($failed.status -lt 400) { throw 'All-down must produce an explicit HTTP error.' }
            Write-Activity 'repairing-routes'
            foreach ($id in @($savedModels.Keys)) { Set-DemoArmProperties $id @{ endpoints=$savedModels[$id] } }
            Write-Activity 'recovery-window' @{seconds=35}
            Wait-Scenario 35000
            Assert-Completion (Send-ScenarioCall 'A' 'demo-chat' 'recovered')
            if ($IncludeAlternateAlias) { Assert-Completion (Send-ScenarioCall 'B' 'demo-alt' 'recovered-secondary') }
            else { Assert-Completion (Send-ScenarioCall 'B' 'demo-chat' 'recovered') }
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
            if ($IncludeAlternateAlias) {
                $alternate = Send-ScenarioCall 'A' 'demo-alt' 'alternate-rejected'
                if ($alternate.status -lt 400) { throw 'Allowance was bypassed, renewed, or not yet consistently enforced.' }
                Assert-Completion (Send-ScenarioCall 'B' 'demo-alt' 'B-alternate')
            }
        }
    }
    $outcome = 'http-observed-awaiting-native-telemetry'
} catch [OperationCanceledException] {
    if (-not $StopPath -or -not (Test-Path -LiteralPath $StopPath)) { throw }
    $outcome = 'stopped-by-operator'
} finally {
    # Failure to publish progress must never prevent restoration.
    try { Write-Activity 'restoring' @{config=(Get-DemoProfileSummary $config baseline); repairs=$savedModels.Count} }
    catch { Write-Warning 'Could not publish restoration progress.' }
    foreach ($id in @($savedModels.Keys)) {
        try { Set-DemoArmProperties $id @{ endpoints=$savedModels[$id] } }
        catch { $restorationFailures.Add("Failed to restore $id : $($_.Exception.Message)") }
    }
    try {
        Set-DemoProfile $config baseline
        try { Write-Activity 'profile-restored' } catch { Write-Warning 'Could not publish restoration confirmation.' }
    }
    catch { $restorationFailures.Add("Failed to restore baseline: $($_.Exception.Message)") }
    @{
        runId=$runId; scenario=$Scenario; gatewayId=$state.gatewayId; outcome=$outcome
        startedBy='PowerShell lab runner'; concurrency=1; clientRetries=0
        conservativeTokenCostEstimateUsd=$estimate; requestCeiling=$requests
        minimumInterRequestSpacingSeconds=$delaySeconds
        workshopRouting=[bool]$WorkshopRouting
        identityBackendFault=[bool]$IdentityBackendFault
        restorationFailures=@($restorationFailures); results=@($results.ToArray())
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath
    Write-Host "HTTP observations saved: $resultPath. Not a native gateway proof until verify-results.ps1 succeeds."
    if ($restorationFailures.Count) { throw ($restorationFailures -join "`n") }
}
