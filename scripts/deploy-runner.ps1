#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$Apply, [string]$Location)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config=Read-DemoConfig $ConfigPath
$state=Get-DemoState $config
if(-not $state.callersProvisioned){throw 'Provision dedicated demo managed identities before deploying this runner.'}
if(-not $Location){$Location=$config.location}
$common=@('--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroupName,
    '--name','demo-managed-callers','--template-file',(Join-Path (Split-Path $PSScriptRoot) 'infra\runner.bicep'),
    '--parameters',"prefix=$($config.gatewayName)","location=$Location",
    "teamAIdentityId=$($state.callerIdentities.A.id)","teamBIdentityId=$($state.callerIdentities.B.id)")
$null=Invoke-DemoAz (@('deployment','group','validate')+$common)
$plan=Invoke-DemoAz (@('deployment','group','what-if','--no-pretty-print')+$common)
$plan|ConvertTo-Json -Depth 30|Write-Host
if(-not $Apply){Write-Host 'Runner validation/what-if only; use -Apply to create the dedicated bounded compute.';return}
$null=Invoke-DemoAz (@('deployment','group','create')+$common)
$runner=Get-DemoArm "$($state.resourceGroupId)/providers/Microsoft.ContainerInstance/containerGroups/$($config.gatewayName)-runner" '2023-05-01'
if($runner.properties.instanceView.state -ne 'Running'){throw 'Managed caller runner is not running.'}
Write-Host 'Dedicated managed caller runner is running; no public ingress. Stop it after live checks. Lifetime is bounded to four hours.'
