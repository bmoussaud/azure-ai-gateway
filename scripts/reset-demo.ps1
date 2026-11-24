#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
Reset-DemoLabFaults $state
& (Join-Path $PSScriptRoot 'configure.ps1') -ConfigPath $ConfigPath -Profile baseline
Write-Host 'Demo endpoint faults and baseline routing restored. Existing counters/exclusions are not erased; wait for renewal/exclusion expiry.'
