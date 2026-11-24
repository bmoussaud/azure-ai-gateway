#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('baseline','weighted-routing','failover','identity-routing','token-rate','token-quota','cost-limit','access-isolation')][string]$Scenario,
    [ValidateRange(50,200)][int]$Samples = 100,
    [string]$BaselineEvidencePath,
    [switch]$IdentityBackendFault
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config=Read-DemoConfig $ConfigPath
$state=Get-DemoState $config
if (-not $state.callersProvisioned) { throw 'This wrapper requires the dedicated demo managed identities.' }
$runnerId="$($state.resourceGroupId)/providers/Microsoft.ContainerInstance/containerGroups/$($config.gatewayName)-runner"
$runner=Get-DemoArm $runnerId '2023-05-01'
if ($runner.tags.demoGateway -cne $config.gatewayName -or $runner.properties.instanceView.state -ne 'Running') {
    throw 'The dedicated managed-caller runner is not running or its ownership marker differs.'
}
foreach($team in @('A','B')){
    if($state.callerIdentities[$team].id -notin $runner.identity.userAssignedIdentities.Keys){
        throw 'Runner does not have the expected demo identities.'
    }
}
$file=[IO.Path]::GetTempFileName()
$socket=[Net.WebSockets.ClientWebSocket]::new()
$timeout=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(90))
$oldA=$env:DEMO_TEAM_A_TOKEN
$oldB=$env:DEMO_TEAM_B_TOKEN
try {
    @{command='/bin/sh';terminalSize=@{rows=24;cols=120}}|ConvertTo-Json|Set-Content -LiteralPath $file
    $exec=Invoke-DemoAz @('rest','--subscription',$config.subscriptionId,'--method','post',
        '--url',"https://management.azure.com$runnerId/containers/runner/exec?api-version=2023-05-01",'--body',"@$file")
    $null=$socket.ConnectAsync([uri]$exec.webSocketUri,$timeout.Token).GetAwaiter().GetResult()
    $auth=[Text.Encoding]::UTF8.GetBytes($exec.password)
    $null=$socket.SendAsync([ArraySegment[byte]]::new($auth),[Net.WebSockets.WebSocketMessageType]::Text,$true,$timeout.Token).GetAwaiter().GetResult()
    $clientA=[guid]::Parse($state.callerIdentities.A.clientId).ToString()
    $clientB=[guid]::Parse($state.callerIdentities.B.clientId).ToString()
    $python=@"
import json,time,urllib.request,urllib.parse
tokens={}
for team,client in [('A','$clientA'),('B','$clientB')]:
    resources=[('','https://ai.gateway.azure.com')]
    if $($Scenario -eq 'access-isolation' ? 'True' : 'False'):
        resources.append(('_foundry','https://cognitiveservices.azure.com'))
    for suffix,resource in resources:
        query=urllib.parse.urlencode({'api-version':'2018-02-01','resource':resource,'client_id':client})
        request=urllib.request.Request('http://169.254.169.254/metadata/identity/oauth2/token?'+query,headers={'Metadata':'true'})
        with urllib.request.urlopen(request,timeout=20) as response:
            credential=json.load(response)
            missing=[name for name in ['access_token','resource','expires_on'] if name not in credential]
            reason='IMDS_FIELDS_MISSING' if missing else None
            if not reason and 'client_id' in credential and credential['client_id'].lower()!=client.lower():
                reason='IMDS_CLIENT_MISMATCH'
            if not reason and credential['resource'].rstrip('/')!=resource.rstrip('/'):
                reason='IMDS_RESOURCE_MISMATCH'
            if not reason and int(credential['expires_on'])<=time.time()+120:
                reason='IMDS_TOKEN_EXPIRING'
            if reason:
                print('DEMO_AUTH_ERROR:'+reason,flush=True)
                raise RuntimeError('IMDS credential metadata rejected')
            tokens[team+suffix]=credential['access_token']
print('DEMO_TOKENS_BEGIN'+json.dumps(tokens)+'DEMO_TOKENS_END',flush=True)
"@
    $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($python))
    $command="python3 -c 'import base64;exec(base64.b64decode(`"$code`"))'`nexit`n"
    $bytes=[Text.Encoding]::UTF8.GetBytes($command)
    $null=$socket.SendAsync([ArraySegment[byte]]::new($bytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,$timeout.Token).GetAwaiter().GetResult()
    $buffer=[byte[]]::new(16384)
    $output=[Text.StringBuilder]::new()
    $match=$null
    while(-not $timeout.IsCancellationRequested){
        $frame=$socket.ReceiveAsync([ArraySegment[byte]]::new($buffer),$timeout.Token).GetAwaiter().GetResult()
        if($frame.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){break}
        $null=$output.Append([Text.Encoding]::UTF8.GetString($buffer,0,$frame.Count))
        $failure=[regex]::Match($output.ToString(),'DEMO_AUTH_ERROR:([A-Z_]+)')
        if($failure.Success){throw "Managed caller acquisition failed: $($failure.Groups[1].Value)."}
        $match=[regex]::Match($output.ToString(),'DEMO_TOKENS_BEGIN(\{[^\r\n]+\})DEMO_TOKENS_END')
        if($match.Success){break}
        if($output.Length -gt 100000){throw 'Managed caller exec output exceeded the safety bound.'}
    }
    if(-not $match -or -not $match.Success){throw 'Managed caller acquisition returned no complete credential envelope.'}
    $tokens=$match.Groups[1].Value|ConvertFrom-Json -AsHashtable
    $env:DEMO_TEAM_A_TOKEN=$tokens.A
    $env:DEMO_TEAM_B_TOKEN=$tokens.B
    $null=Get-DemoToken A $config
    $null=Get-DemoToken B $config
    if($Scenario -eq 'access-isolation'){
        $null=Assert-DemoRunBudget $config 4
        $results=[Collections.Generic.List[object]]::new()
        foreach($team in @('A','B')){
            foreach($backend in @(1,2)){
                $project=$state.projects["project-$backend"]
                $foundry=[uri]$project.endpoint
                if($foundry.Scheme -ne 'https' -or -not $foundry.Host.EndsWith('.cognitiveservices.azure.com') -or
                    $foundry.UserInfo -or $foundry.Query -or $foundry.Fragment){throw 'Unexpected dedicated Foundry endpoint.'}
                $foundryToken=$tokens["${team}_foundry"]
                $url="$($foundry.AbsoluteUri.TrimEnd('/'))/openai/v1/chat/completions"
                $r=Invoke-DemoRequest $url $project.deploymentName $foundryToken $team 'direct-foundry-denied'
                $r.target=$project.deploymentId
                $results.Add($r)
                if($r.status -notin @(401,403) -or $r.errorCode -ne 'PermissionDenied'){
                    throw "Expected native PermissionDenied with a correctly scoped token; HTTP $($r.status), code=$($r.errorCode), trace $($r.traceId)."
                }
                Write-Host "Direct Foundry: team $team backend $backend HTTP $($r.status) PermissionDenied."
            }
        }
        $directory=Join-Path (Split-Path $PSScriptRoot) '.demo'
        $null=New-Item -ItemType Directory -Path $directory -Force
        $path=Join-Path $directory "access-$([guid]::NewGuid().ToString('N')).json"
        @{scenario=$Scenario;gatewayId=$state.gatewayId;results=@($results.ToArray());outcome='four-native-foundry-permission-denials'}|
            ConvertTo-Json -Depth 15|Set-Content -LiteralPath $path
        Write-Host "Both callers denied direct access to both Foundry deployments with correctly scoped tokens: $path"
        return
    }
    $run=@{ConfigPath=$ConfigPath;Scenario=$Scenario;Samples=$Samples}
    if ($IdentityBackendFault) { $run.IdentityBackendFault=$true }
    if($BaselineEvidencePath){$run.BaselineEvidencePath=$BaselineEvidencePath}
    & (Join-Path $PSScriptRoot 'run-scenario.ps1') @run
} finally {
    $env:DEMO_TEAM_A_TOKEN=$oldA
    $env:DEMO_TEAM_B_TOKEN=$oldB
    $socket.Dispose()
    $timeout.Dispose()
    Remove-Item -LiteralPath $file -Force
}
