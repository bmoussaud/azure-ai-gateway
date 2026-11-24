#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','token-rate','token-quota','reset')][string]$Scenario,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Scenario -eq 'reset') {
    & (Join-Path $PSScriptRoot 'reset-demo.ps1') -ConfigPath $ConfigPath
} else {
    & (Join-Path $PSScriptRoot 'run-scenario.ps1') -ConfigPath $ConfigPath -Scenario $Scenario `
        -Samples 50 -OutputDirectory $OutputDirectory -EventPath (Join-Path $OutputDirectory 'events.jsonl') `
        -ActivityPath (Join-Path $OutputDirectory 'activity.jsonl') -StopPath (Join-Path $OutputDirectory 'stop.requested')
}
