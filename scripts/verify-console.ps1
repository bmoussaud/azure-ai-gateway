#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Url, [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot) '.demo\console-acceptance.json'), [switch]$LiveBaselineOnly)
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
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $state = Read-Console
        $job = @($state.jobs | Where-Object id -CEQ $Id)
        if ($job.Count -ne 1) { throw 'Hosted job disappeared or was duplicated; evidence is not complete.' }
        if ($job[0].status -ne $previous) {
            $previous = $job[0].status
            Write-Host "$($job[0].scenario): $previous"
        }
        if ($LiveBaselineOnly -and $state.busy -and $job[0].requests.Count -lt 4 -and
            @($job[0].activity | Where-Object kind -CEQ 'sending').Count) {
            if (-not $inFlight) { Write-Host 'Observed a live dispatch before all baseline responses arrived.' }
            $inFlight = $true
        }
        if ($previous -eq 'failed') { throw "Hosted scenario failed: $($job[0].error)" }
        if ($previous -in @('verified','complete') -and -not $state.busy) {
            if (-not $job[0].restored) { throw 'Hosted job did not confirm baseline restoration.' }
            if ($LiveBaselineOnly -and (-not $inFlight -or $job[0].requests.Count -ne 4 -or
                @($job[0].activity | Where-Object kind -CEQ 'responded').Count -ne 4 -or
                $job[0].activity[-1].kind -cne 'verified')) { throw 'Live baseline journal evidence incomplete.' }
            return $job[0]
        }
        Start-Sleep -Seconds 5
    }
    throw 'Hosted verification timed out. No second traffic job was submitted.'
}
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
do {
    $state = Read-Console
    if ($state.error) { throw "Console is not ready: $($state.error)" }
    if ($state.ready) { break }
    if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Managed identity/startup reset did not become ready.' }
    Start-Sleep -Seconds 5
} while ($true)
if ($state.busy) { throw 'Another hosted scenario is already running; acceptance will not interfere.' }
$page = Invoke-WebRequest $Url -Headers $authorization -TimeoutSec 30
if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'id="team-a"' -or
    $page.Content -notmatch 'id="team-b"') { throw 'HTTPS page does not contain both application panels.' }
$csrf = Invoke-WebRequest "$Url/api/run" -Method Post -ContentType application/json `
    -Headers $authorization -Body '{"scenario":"baseline"}' -SkipHttpErrorCheck -TimeoutSec 30
if ($csrf.StatusCode -ne 403) { throw 'An authenticated action without CSRF protection was not refused.' }
$run = Invoke-ConsoleAction baseline
$overlapHeaders = $authorization.Clone()
$overlapHeaders.Origin = $Url
$overlapHeaders.'X-Demo-Csrf' = $state.csrf
$overlap = Invoke-WebRequest "$Url/api/run" -Method Post -ContentType application/json `
    -Headers $overlapHeaders -Body '{"scenario":"baseline"}' -SkipHttpErrorCheck -TimeoutSec 30
if ($overlap.StatusCode -ne 409) { throw 'Overlapping scenario was not refused.' }
$jobs = [Collections.Generic.List[object]]::new()
$jobs.Add((Wait-ConsoleJob $run.id))
if ($LiveBaselineOnly) {
    $jobs[0] | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath
    Write-Host 'Live baseline verified: 4 responses, native evidence and restored gateway.'
    return
}
foreach ($scenario in @('failover','token-rate','reset')) {
    $run = Invoke-ConsoleAction $scenario
    $jobs.Add((Wait-ConsoleJob $run.id))
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
    jobs=@($jobs.ToArray()); visualBrowserObserved=$false
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath
Write-Host "HTTPS console acceptance verified and saved: $OutputPath"
