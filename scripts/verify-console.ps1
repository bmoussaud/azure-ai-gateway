#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Url, [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot) '.demo\console-acceptance.json'), [switch]$LiveBaselineOnly, [switch]$StopAfterFirstResponse, [switch]$WorkshopRoutingOnly, [switch]$IdentityRoutingOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$uri = [uri]$Url
if ($uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or
    $uri.Host -cnotmatch '^[a-z0-9.-]+\.azurecontainerapps\.io$' -or $uri.AbsolutePath -ne '/') {
    throw 'Expected the deployed Container Apps HTTPS origin, not an arbitrary credential destination.'
}
$Url = $Url.TrimEnd('/')
$authorization = @{}
if ($env:DEMO_CONSOLE_TOKEN) { $authorization.Authorization = "Bearer $env:DEMO_CONSOLE_TOKEN" }
function Read-Console { Invoke-RestMethod "$Url/api/state" -Headers $authorization -TimeoutSec 30 }
function Invoke-ConsoleAction([string]$Scenario) {
    $state = Read-Console
    $headers = $authorization.Clone()
    $headers.Origin = $Url
    $headers.'X-Demo-Csrf' = $state.csrf
    Invoke-RestMethod "$Url/api/run" -Method Post -ContentType application/json `
        -Headers $headers -Body (@{scenario=$Scenario} | ConvertTo-Json -Compress) -TimeoutSec 30
}
function Wait-ConsoleJob([string]$Id) {
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(35)
    $previous = ''
    $inFlight = $false
    $stopSent = $false
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $state = Read-Console
        $job = @($state.jobs | Where-Object id -CEQ $Id)
        if ($job.Count -ne 1) { throw 'Hosted job disappeared or was duplicated; evidence is not complete.' }
        if ($job[0].status -ne $previous) {
            $previous = $job[0].status
            Write-Host "$($job[0].scenario): $previous"
        }
        if ($LiveBaselineOnly -and $state.busy -and $job[0].requests.Count -lt 2 -and
            @($job[0].activity | Where-Object kind -CEQ 'sending').Count) {
            if (-not $inFlight) { Write-Host 'Observed a live dispatch before all baseline responses arrived.' }
            $inFlight = $true
        }
        if ($previous -eq 'failed') { throw "Hosted scenario failed: $($job[0].error)" }
        if ($StopAfterFirstResponse -and -not $stopSent -and $job[0].requests.Count) {
            $headers = $authorization.Clone()
            $headers.Origin = $Url
            $headers.'X-Demo-Csrf' = $state.csrf
            $null = Invoke-RestMethod "$Url/api/stop" -Method Post -ContentType application/json `
                -Headers $headers -Body (@{id=$Id} | ConvertTo-Json -Compress) -TimeoutSec 30
            $stopSent = $true
        }
        if ($StopAfterFirstResponse -and $previous -eq 'stopped' -and -not $state.busy) {
            if (-not $stopSent -or -not $state.ready -or -not $job[0].restored -or
                $job[0].requests.Count -ne 1 -or $job[0].activity[-1].kind -ne 'stopped') {
                throw 'Expected a partial baseline, unchanged configuration and released controls.'
            }
            Write-Host "Start/Stop confirmed: $($job[0].requests.Count) of 2 responses retained, configuration unchanged, ready."
            return $job[0]
        }
        if ($previous -in @('verified','complete') -and -not $state.busy) {
            if ($StopAfterFirstResponse) { throw 'Baseline completed instead of stopping.' }
            if (-not $job[0].restored) { throw 'Hosted job did not confirm unchanged configuration.' }
            if ($LiveBaselineOnly -and (-not $inFlight -or $job[0].requests.Count -ne 2 -or
                @($job[0].activity | Where-Object kind -CEQ 'responded').Count -ne 2 -or
                $job[0].activity[-1].kind -cne 'verified')) { throw 'Live baseline journal evidence incomplete.' }
            return $job[0]
        }
        Start-Sleep -Seconds ($StopAfterFirstResponse ? 1 : 5)
    }
    throw 'Hosted verification timed out. No second traffic job was submitted.'
}
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
do {
    $state = Read-Console
    if ($state.error) { throw "Console is not ready: $($state.error)" }
    if ($state.ready) { break }
    if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Managed identity/startup verification did not become ready.' }
    Start-Sleep -Seconds 5
} while ($true)
if ($state.busy) { throw 'Another hosted scenario is already running; acceptance will not interfere.' }
$page = Invoke-WebRequest $Url -Headers $authorization -TimeoutSec 30
if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'id="team-a"' -or
    $page.Content -notmatch 'id="team-b"') { throw 'HTTPS page does not contain both application panels.' }
$csrf = Invoke-WebRequest "$Url/api/run" -Method Post -ContentType application/json `
    -Headers $authorization -Body '{"scenario":"baseline"}' -SkipHttpErrorCheck -TimeoutSec 30
if ($csrf.StatusCode -ne 403) { throw 'An authenticated action without CSRF protection was not refused.' }
$run = Invoke-ConsoleAction ($IdentityRoutingOnly ? 'identity-routing' : $WorkshopRoutingOnly ? 'weighted-routing' : 'baseline')
$overlapHeaders = $authorization.Clone()
$overlapHeaders.Origin = $Url
$overlapHeaders.'X-Demo-Csrf' = $state.csrf
$overlap = Invoke-WebRequest "$Url/api/run" -Method Post -ContentType application/json `
    -Headers $overlapHeaders -Body '{"scenario":"baseline"}' -SkipHttpErrorCheck -TimeoutSec 30
if ($overlap.StatusCode -ne 409) { throw 'Overlapping scenario was not refused.' }
$jobs = [Collections.Generic.List[object]]::new()
$jobs.Add((Wait-ConsoleJob $run.id))
if ($WorkshopRoutingOnly) {
    $j = $jobs[0]
    $pauses = @($j.activity | Where-Object kind -eq 'pacing')
    if ($j.status -ne 'verified' -or $j.requestCeiling -ne 10 -or $j.requests.Count -ne 10 -or
        $j.native.Count -ne 10 -or @($j.requests | Where-Object status -ne 200).Count -or
        $j.minimumSpacingSeconds -gt 2 -or @($pauses | Where-Object seconds -gt 2).Count) {
        throw 'Ten native-backed responses with a two-second pacing cap were not observed.'
    }
    $primary = @($j.native | Where-Object Backend -eq 'backend-1/demo-model').Count
    Write-Host "Workshop routing: 10/10 HTTP 200; primary $primary, secondary $(10-$primary); pacing $($j.minimumSpacingSeconds)s."
}
if ($IdentityRoutingOnly) {
    $j = $jobs[0]
    if ($j.status -ne 'verified' -or $j.requests.Count -ne 10 -or $j.native.Count -ne 10 -or
        $j.requestCeiling -ne 10 -or $j.minimumSpacingSeconds -gt 2 -or $j.clientRetries -ne 0 -or
        @($j.activity | Where-Object { $_.kind -eq 'pacing' -and $_.seconds -gt 2 }).Count) {
        throw 'Identity HTTPS scenario did not confirm ten bounded, natively verified calls.'
    }
    foreach ($team in @('A','B')) {
        $calls = @($j.requests | Where-Object team -CEQ $team)
        $expected = if ($team -ceq 'B') { 'backend-2/demo-model' } else { 'backend-1/demo-model' }
        if ($calls.Count -ne 5 -or @($calls | Where-Object { $_.status -ne 200 -or $_.alias -cne 'scenario-identity' }).Count -or
            @($j.native | Where-Object { $_.TraceId -cin $calls.traceId -and $_.Backend -ceq $expected -and $_.Attempts -eq 1 }).Count -ne 5) {
            throw "Identity HTTPS scenario did not prove five $team calls on $expected."
        }
    }
    Write-Host 'Native identity routing: A -> Backend 1 (5/5), B -> Backend 2 (5/5), no fallback or client retry, configuration unchanged.'
}
if ($LiveBaselineOnly -or $StopAfterFirstResponse -or $WorkshopRoutingOnly -or $IdentityRoutingOnly) {
    $jobs[0] | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath
    if ($LiveBaselineOnly) { Write-Host 'Live baseline verified: 2 responses, native evidence and unchanged gateway.' }
    return
}
foreach ($scenario in @('weighted-routing','failover','token-rate','token-quota','identity-routing','reset')) {
    $run = Invoke-ConsoleAction $scenario
    $jobs.Add((Wait-ConsoleJob $run.id))
}
foreach ($job in @($jobs | Where-Object scenario -NE 'reset')) {
    if ($job.status -cne 'verified' -or -not $job.configurationUnchanged -or
        $job.requests.Count -gt 10 -or $job.requests.Count -ne $job.native.Count -or
        $job.minimumSpacingSeconds -gt 2 -or $job.clientRetries -ne 0 -or
        @($job.requests | Where-Object alias -CNE $job.alias).Count -or
        @($job.native | Where-Object Alias -CNE $job.alias).Count -or
        @($job.activity | Where-Object { $_.kind -in @('applying-profile','restoring','injecting','repair') }).Count) {
        throw 'Fixed scenario acceptance needs its own native alias, no configuration changes and bounded traffic.'
    }
}
$minute = @($jobs | Where-Object scenario -EQ 'token-rate')[0]
if (@($minute.requests | Where-Object { $_.team -eq 'A' -and $_.status -eq 429 }).Count -lt 1 -or
    @($minute.requests | Where-Object { $_.team -eq 'B' -and $_.status -eq 200 }).Count -lt 1) {
    throw 'HTTPS acceptance did not observe A minute rejection while B completes.'
}
@{
    url=$Url; verifiedAt=[DateTimeOffset]::UtcNow.ToString('o')
    source='Actual HTTPS scenario API, server A/B managed identities and native telemetry verifier'
    noCsrfStatus=$csrf.StatusCode; overlappingStatus=$overlap.StatusCode
    configurationMode='fixed-alias'
    jobs=@($jobs.ToArray()); visualBrowserObserved=$false
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath
Write-Host "HTTPS console acceptance verified and saved: $OutputPath"
