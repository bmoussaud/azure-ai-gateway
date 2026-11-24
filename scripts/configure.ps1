#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','token-rate','token-quota','cost-limit')][string]$Profile
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$null = Get-DemoState $config
Set-DemoProfile $config $Profile
Write-Host "Profile $Profile persisted and read back. Counter reset is NOT implied."
