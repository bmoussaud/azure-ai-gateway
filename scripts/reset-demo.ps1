#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
foreach ($scenario in @('baseline','weighted-routing','failover','identity-routing','token-rate','token-quota')) {
    $null = Assert-DemoFixedScenario $config $scenario
}
Write-Host 'Fixed aliases verified without changes. Counters are not erased; wait for natural renewal.'
