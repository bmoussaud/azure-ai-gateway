#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','identity-routing','token-rate','token-quota','reset')][string]$Scenario,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Scenario -eq 'reset') {
    & (Join-Path $PSScriptRoot 'reset-demo.ps1') -ConfigPath $ConfigPath
} else {
    if ($env:APPLICATIONINSIGHTS_CONNECTION_STRING) {
        $env:DEMO_CALLER_SPANS_PATH = Join-Path $OutputDirectory 'caller-spans.jsonl'
    }
    & (Join-Path $PSScriptRoot 'run-scenario.ps1') -ConfigPath $ConfigPath -Scenario $Scenario `
        -WorkshopRouting:($Scenario -eq 'weighted-routing') -OutputDirectory $OutputDirectory -EventPath (Join-Path $OutputDirectory 'events.jsonl') `
        -ActivityPath (Join-Path $OutputDirectory 'activity.jsonl') -StopPath (Join-Path $OutputDirectory 'stop.requested')
}
