#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot
$module = Import-Module (Join-Path $root 'scripts\Demo.psm1') -Force -PassThru
$script:Checks = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    $script:Checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message, [string]$Pattern = '.*') {
    $threw = $false
    try { & $Action } catch { $threw = $_.Exception.Message -match $Pattern }
    Assert-True $threw $Message
}

$parseFailures = @()
foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -File | Where-Object Extension -in @('.ps1','.psm1')) {
    $tokens=$null; $errors=$null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $parseFailures += @($errors)
}
Assert-True ($parseFailures.Count -eq 0) ($parseFailures -join "`n")
Assert-True (Test-DemoSubset @{ policies=@(@{ id='p'; count=10 }) } @{ etag='x'; policies=@(@{ count=10; id='p'; scope='workspace' }) }) 'Read-back subset should ignore provider-added fields.'
Assert-True (-not (Test-DemoSubset @{ policies=@() } @{ policies=@(@{id='p'}) })) 'Removing a policy must not be a no-op.'
Assert-True (Test-DemoSubset @{policies=@()} @{}) 'The live native alias API omits empty optional policy arrays.'
Assert-True (-not (Test-DemoSubset @{policies=@(@{id='p'})} @{})) 'Missing policies must not match a nonempty policy configuration.'
Assert-True (-not (Test-DemoSubset @{backendModels=@()} @{})) 'Only the known optional empty policy field may be omitted.'
Assert-True (Test-DemoSubset @{policies=@(@{id='demo-test';type='tokenLimit';count=256})} @{policies=@(@{type='tokenLimit';count=256})}) 'Live native policy responses omit the submitted policy ID.'
Assert-True (-not (Test-DemoSubset @{policies=@(@{id='demo-test';type='tokenLimit';count=256})} @{policies=@(@{type='tokenLimit';count=257})})) 'An omitted policy ID must not hide a changed allowance.'
Assert-True (-not (Test-DemoSubset @{ backends=@('a','b') } @{ backends=@('b','a') })) 'Routing order is significant.'
Assert-True (-not (Test-DemoSubset @{ count=10 } @{ count=11 })) 'Changed allowance must be detected.'
Assert-Throws {Assert-DemoWeightedDistribution 50 50} 'The small-sample tolerance must not certify traffic served by only one backend.'
Assert-Throws {Assert-DemoWeightedDistribution 10 100} 'A materially incorrect routing distribution must be refused.'
Assert-True ((Assert-DemoWeightedDistribution 80 100) -gt 0) 'A representative 80/20 distribution should pass.'
Assert-Throws {
    Get-DemoRequestsQuery @{hostname="invalid'; take 1";gatewayId='/invalid';insightsId='/invalid';resourceGroupId='/invalid'}
} 'Query interpolation must refuse a malformed gateway hostname.' 'refusing KQL interpolation'
Assert-Throws {
    Get-DemoRequestsQuery @{
        hostname='gateway.example.test'
        gatewayId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-aigw-demo-local/providers/Microsoft.ApiManagement/aigateways/demo'
        resourceGroupId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-aigw-demo-local'
        insightsId='/another/component'
    }
} 'An Insights-scoped query must not admit another component.' 'refusing KQL interpolation'

$c = @{
    subscriptionId='11111111-1111-1111-1111-111111111111'; resourceGroupName='rg-aigw-demo-local'
    location='eastus2'; secondaryLocation='eastus2'; monitoringLocation='eastus2'
    gatewayName='demo-local-test'; gatewaySku='Standard'; modelName='test-model'; modelVersion='test-version'
    deploymentName='test-model'; modelSku='GlobalStandard'; modelCapacity=1
    teamAObjectId='22222222-2222-2222-2222-222222222222'; teamBObjectId='33333333-3333-3333-3333-333333333333'
    inputUsdPerMillion=1.0; outputUsdPerMillion=2.0; maxRunEstimatedUsd=1.0; priceSource='Synthetic unit-test prices, not real rates'
}
$temp = [IO.Path]::GetTempFileName()
$oldTokenA = $env:DEMO_TEAM_A_TOKEN
try {
    $c | ConvertTo-Json | Set-Content -LiteralPath $temp
    $read = Read-DemoConfig $temp
    Assert-True ($read.subscriptionId -eq $c.subscriptionId) 'Explicit subscription must be retained.'
    $bad = $c.Clone(); $bad.resourceGroupName='production'
    $bad | ConvertTo-Json | Set-Content -LiteralPath $temp
    Assert-Throws { Read-DemoConfig $temp } 'Non-demo resource groups must be refused.'
    $bad = $c.Clone(); $bad.subscriptionId=''
    $bad | ConvertTo-Json | Set-Content -LiteralPath $temp
    Assert-Throws { Read-DemoConfig $temp } 'An implicit default subscription must be refused.'
    $bad = $c.Clone(); $bad.teamBObjectId=$bad.teamAObjectId
    $bad | ConvertTo-Json | Set-Content -LiteralPath $temp
    Assert-Throws { Read-DemoConfig $temp } 'Identical A/B principals must be refused.'
    $bad=$c.Clone();$bad.gatewaySku='Consumption'
    $bad|ConvertTo-Json|Set-Content -LiteralPath $temp
    Assert-Throws {Read-DemoConfig $temp} 'Generic APIM SKU options must not bypass the native Standard-only gateway contract.'
    $managed=$c.Clone();$managed.Remove('teamAObjectId');$managed.Remove('teamBObjectId');$managed.provisionDemoCallers=$true
    $managed|ConvertTo-Json|Set-Content -LiteralPath $temp
    Assert-True ((Read-DemoConfig $temp).provisionDemoCallers) 'Dedicated callers must be an explicit opt-in.'
    $managed.teamAObjectId=$c.teamAObjectId
    $managed|ConvertTo-Json|Set-Content -LiteralPath $temp
    Assert-Throws {Read-DemoConfig $temp} 'Provisioned callers must not silently replace supplied external identities.'

    $payload = @{ oid=$c.teamAObjectId; aud='https://ai.gateway.azure.com'; exp=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds() } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $env:DEMO_TEAM_A_TOKEN = "e30.$encoded.signature"
    Assert-True ((Get-DemoToken A $c) -eq $env:DEMO_TEAM_A_TOKEN) 'A token matching the expected workload must be accepted locally.'
    $swapped = $c.Clone(); $swapped.teamAObjectId=$c.teamBObjectId
    Assert-Throws { Get-DemoToken A $swapped } 'Swapped workload tokens must be refused before HTTP.'
    $env:DEMO_TEAM_A_TOKEN='not-a-token'
    Assert-Throws { Get-DemoToken A $c } 'Malformed tokens must be refused.'
    $expired=@{oid=$c.teamAObjectId;aud='https://ai.gateway.azure.com';exp=1}|ConvertTo-Json -Compress
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expired)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $env:DEMO_TEAM_A_TOKEN="e30.$encoded.signature"
    Assert-Throws { Get-DemoToken A $c } 'Expired tokens must be refused before HTTP.'
    Assert-True ((Assert-DemoRunBudget $c 10 2) -gt 0) 'Run estimate must include backend retry attempts.'
    $cheap = $c.Clone(); $cheap.maxRunEstimatedUsd=0.000001
    Assert-Throws { Assert-DemoRunBudget $cheap 10 2 } 'Traffic over the configured conservative ceiling must be refused.'
    $unpriced = $c.Clone(); $unpriced.outputUsdPerMillion=0
    Assert-Throws { Assert-DemoRunBudget $unpriced 10 } 'Unpriced traffic must be refused.'
    $unpriced.outputUsdPerMillion=[double]::NaN
    Assert-Throws { Assert-DemoRunBudget $unpriced 10 } 'Nonfinite prices must not bypass the run ceiling.'
    Assert-Throws { Assert-DemoPricingSeries @() } 'Missing metrics must not authorize cost-limit traffic.'
    Assert-Throws { Assert-DemoPricingSeries @(@{metric=@{'azure.ai_gateway.price_missing'='true'};value=@(1,'0.01')}) } 'Partially priced usage must not authorize cost-limit traffic.'
    Assert-Throws { Assert-DemoPricingSeries @(@{metric=@{};value=@(1,'0.01')}) } 'An absent completeness flag must remain unknown.'
    Assert-DemoPricingSeries @(@{metric=@{'azure.ai_gateway.price_missing'='false'};value=@(1,'0.01')})
    $script:Checks++
} finally {
    $env:DEMO_TEAM_A_TOKEN=$oldTokenA
    Remove-Item -LiteralPath $temp -Force
}

& $module {
    $script:ExpectedQuery = "let Value = 'quoted';`nprint Result=Value"
    function script:Invoke-DemoAz {
        param([string[]]$Arguments)
        $body=Get-Content -LiteralPath $Arguments[-1].Substring(1) -Raw|ConvertFrom-Json -AsHashtable
        if($body.query -cne $script:ExpectedQuery -or $body.timespan -ne 'PT1H'){
            throw 'KQL must reach the native query endpoint with quotes and line breaks intact.'
        }
        return @{tables=@(@{columns=@(@{name='Result'});rows=@(,@('native-shape'))})}
    }
    $rows=@(Invoke-DemoQuery @{subscriptionId='s'} @{logAnalyticsCustomerId='w'} $script:ExpectedQuery)
    if($rows.Count -ne 1 -or $rows[0].Result -ne 'native-shape'){throw 'Native table columns must map to the corresponding row values.'}
}
$script:Checks++

& $module {
    $script:Writes=0
    $script:Observed=@{policies=@()}
    function script:Get-DemoArmEnvelope { param($Id); return @{body=@{properties=$script:Observed};etag='"revision-1"'} }
    function script:Get-DemoArm { param($Id); return @{properties=$script:Observed} }
    function script:Invoke-DemoAz {
        param([string[]]$Arguments)
        if ($Arguments -notcontains 'If-Match="revision-1"') { throw 'Missing concurrency guard.' }
        $bodyPath = $Arguments[-1].Substring(1)
        $script:Observed = (Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json -AsHashtable).properties
        $script:Writes++
    }
    $id='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-aigw-demo-local/providers/Microsoft.ApiManagement/aigateways/g'
    Set-DemoArmProperties $id @{policies=@()}
    if ($script:Writes -ne 0) { throw 'Idempotent configuration wrote unnecessarily.' }
    Set-DemoArmProperties $id @{policies=@(@{id='demo-test';type='tokenLimit';count=10})}
    if ($script:Writes -ne 1) { throw 'Changed configuration was not applied exactly once.' }
    Set-DemoArmProperties $id @{policies=@(@{id='demo-test';type='tokenLimit';count=10})}
    if ($script:Writes -ne 1) { throw 'Repeated configuration was not idempotent.' }
}
$script:Checks += 3

Assert-Throws {
    & $module {
        function script:Get-DemoArmEnvelope { return @{body=@{properties=@{policies=@()}};etag='"revision-1"'} }
        function script:Get-DemoArm { return @{properties=@{policies=@()}} }
        function script:Invoke-DemoAz {}
        function script:Start-Sleep {}
        Set-DemoArmProperties '/subscriptions/s/resourceGroups/r' @{policies=@(@{id='new'})}
    }
} 'Configuration must fail if read-back never converges.' 'Configuration read-back timed out'
Assert-Throws {
    & $module {
        function script:Get-DemoArm { return @{properties=@{provisioningState='Failed'}} }
        Set-DemoArmProperties '/subscriptions/s/resourceGroups/r' @{policies=@(@{id='new'})}
    }
} 'Failed provisioning must not become successful configuration.' 'Configuration failed'
Assert-Throws {
    & $module {
        function script:Invoke-DemoAz {
            return @{id='/subscriptions/s/resourceGroups/rg-aigw-demo-local';tags=@{
                purpose='ai-gateway-demo';managedBy='azure-ai-gateway-demo';demoGateway='another-gateway'
            }}
        }
        Assert-DemoGroup @{subscriptionId='s';resourceGroupName='rg-aigw-demo-local';gatewayName='our-gateway'}
    }
} 'Another gateway ownership marker must prevent mutation.' 'ownership markers do not match'

& $module {
    function script:Assert-DemoGroup {}
    function script:Get-DemoArm { param($Id); return @{properties=@{policies=@();supportedEndpoints=@('v1/chat/completions');gatewayEndpoints=@(@{
        api='v1/chat/completions';url='https://assigned.example.test/default/models/openai/v1/chat/completions'
    })}} }
    function script:Get-DemoArmEnvelope { param($Id); return @{body=(Get-DemoArm $Id);etag='"revision-1"'} }
    $script:ProfileWrites=@{}
    $script:ProfileMethods=@{}
    function script:Set-DemoArmProperties { param($Id,$Properties,$Method,$Current); $script:ProfileWrites[$Id]=$Properties; $script:ProfileMethods[$Id]=$Method }
    $config=@{subscriptionId='s';resourceGroupName='r';gatewayName='g';teamAObjectId='a'}
    Set-DemoProfile $config token-rate
    $ids=Get-DemoIds $config
    $policy=$script:ProfileWrites[$ids.workspace].policies[0]
    if ($policy.scope -ne 'workspace' -or $policy.counterKey.Count -ne 1 -or $policy.counterKey[0] -ne 'identity') {
        throw 'Allowance must share a workspace counter keyed only by authenticated identity.'
    }
    if ($script:ProfileWrites["$($ids.workspace)/aliases/demo-alt"].backendModels[0].priority -ne 1) {
        throw 'The alternate alias must prove non-bypass through the other preferred backend.'
    }
    if ($script:ProfileWrites["$($ids.workspace)/aliases/demo-chat"].ContainsKey('maxRetryAttempts') -or
        $script:ProfileMethods["$($ids.workspace)/aliases/demo-chat"] -ne 'put') {
        throw 'Disabled failure actions must omit the attempt budget and replace the old alias configuration.'
    }
    Set-DemoProfile $config cost-limit
    if ($script:ProfileWrites[$ids.workspace].policies[0].overrides[0].claims[0].value -ne 'a') {
        throw 'Cost override must select the configured authenticated A identity, not a caller header.'
    }
    $endpoint=Get-DemoRuntimeEndpoint @{workspaceId='/synthetic';hostname='assigned.example.test'}
    if ($endpoint -ne 'https://assigned.example.test/default/models/openai/v1/chat/completions') {
        throw 'Runtime must use the alias-advertised endpoint and service-assigned hostname.'
    }
    function script:Get-DemoArm {
        param($Id)
        $paths=if($Id.EndsWith('demo-chat')){@()}else{@(@{
            api='v1/chat/completions';url='https://assigned.example.test/default/models/openai/v1/chat/completions'
        })}
        return @{properties=@{gatewayEndpoints=$paths}}
    }
    $refused=$false
    try { Get-DemoRuntimeEndpoint @{workspaceId='/synthetic';hostname='assigned.example.test'} }
    catch { $refused=$_.Exception.Message -like 'Both aliases must advertise*' }
    if(-not $refused){throw 'An unadvertised first alias must not inherit the second alias endpoint.'}
    function script:Get-DemoArm { return @{properties=@{endpoints=@(@{api='v1/chat/completions';path='/demo-injected-unavailable'})}} }
    Reset-DemoLabFaults @{workspaceId='/synthetic'}
    foreach($backend in @(1,2)){
        if($script:ProfileWrites["/synthetic/modelProviders/backend-$backend/models/demo-model"].endpoints[0].path -ne '/openai/v1/chat/completions'){
            throw 'Reset must repair recognized lab faults on both backends.'
        }
    }
    function script:Get-DemoArm { return @{properties=@{endpoints=@(@{api='v1/chat/completions';path='/foreign-route'})}} }
    $refused=$false
    try { Reset-DemoLabFaults @{workspaceId='/synthetic'} }
    catch { $refused=$_.Exception.Message -like 'Unexpected model mapping*' }
    if(-not $refused){throw 'Reset must refuse foreign endpoint mappings.'}
}
$script:Checks += 8
Assert-Throws {
    & $module {
        function script:Get-DemoArm {
            return @{properties=@{policies=@(@{type='tokenLimit';count=257;period='minute';counterKey=@('identity');scope='workspace'})}}
        }
        Set-DemoProfile @{subscriptionId='s';resourceGroupName='r';gatewayName='g';teamAObjectId='a'} baseline
    }
} 'Policy ID omission must not authorize replacing an unrecognized allowance.' 'Unexpected workspace policies'
& $module {
    $script:CallerState=@{
        gatewayId='/subscriptions/s/resourceGroups/r/providers/Microsoft.ApiManagement/aigateways/g'
        resourceGroupId='/subscriptions/s/resourceGroups/r';callersProvisioned=$true
        teamAObjectId='a';teamBObjectId='b'
        callerIdentities=@{
            A=@{id='/subscriptions/s/resourceGroups/r/providers/Microsoft.ManagedIdentity/userAssignedIdentities/g-team-a';principalId='a'}
            B=@{id='/subscriptions/s/resourceGroups/r/providers/Microsoft.ManagedIdentity/userAssignedIdentities/g-team-b';principalId='b'}
        }
    }
    function script:Invoke-DemoAz { return $script:CallerState }
    $config=@{subscriptionId='s';resourceGroupName='r';gatewayName='g';provisionDemoCallers=$true}
    $null=Get-DemoState $config
    if($config.teamAObjectId -ne 'a' -or $config.teamBObjectId -ne 'b'){
        throw 'Provisioned caller IDs must resolve from verified, dedicated deployment outputs.'
    }
    $script:CallerState.callerIdentities.A.id='/another-group/another-identity'
    $refused=$false
    try {Get-DemoState $config}
    catch {$refused=$_.Exception.Message -like 'Dedicated caller identity outputs do not match*'}
    if(-not $refused){throw 'Caller resolution must refuse identities outside the owned demo group.'}
}
$script:Checks += 2
& $module {
    $script:PublisherReads=0
    $script:PublisherWrites=0
    $rule='/subscriptions/s/resourceGroups/managed/providers/Microsoft.Insights/dataCollectionRules/native'
    $component='/subscriptions/s/resourceGroups/demo/providers/Microsoft.Insights/components/demo'
    $script:PublisherRule=$rule
    $script:PublisherComponent=$component
    function script:Get-DemoArm {
        param($Id,$ApiVersion)
        $script:PublisherReads++
        if($Id -eq $script:PublisherComponent){return @{properties=@{DataCollectionRuleResourceId=$script:PublisherRule}}}
        if($Id -eq $script:PublisherRule){return @{properties=@{references=@{applicationInsights=@(@{resourceId=$script:PublisherComponent})}}}}
        if($Id.EndsWith('/roleAssignments')){return @{value=@(@{properties=@{
            principalId='gateway-principal';scope=$script:PublisherRule
            roleDefinitionId='/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb'
        }})}}
        return @{identity=@{principalId='gateway-principal'}}
    }
    function script:Invoke-DemoAz { $script:PublisherWrites++; throw 'Unexpected publisher write.' }
    Set-DemoInsightsPublisher @{subscriptionId='s'} @{insightsId=$component;gatewayId='/subscriptions/s/resourceGroups/demo/providers/Microsoft.ApiManagement/aigateways/g'}
    if($script:PublisherWrites -ne 0){throw 'An existing exact-DCR publisher grant must be an idempotent no-op.'}
    $script:PublisherRule='/subscriptions/other/resourceGroups/managed/providers/Microsoft.Insights/dataCollectionRules/native'
    $refused=$false
    try {Set-DemoInsightsPublisher @{subscriptionId='s'} @{insightsId=$component}}
    catch {$refused=$_.Exception.Message -like '*unexpected managed DCR subscription*'}
    if(-not $refused){throw 'Publisher grant must refuse a DCR in another subscription.'}
    $script:PublisherRule=$rule
    $script:PublisherComponent='/a-different-component'
    function script:Get-DemoArm {
        param($Id,$ApiVersion)
        if($Id -eq '/expected'){return @{properties=@{DataCollectionRuleResourceId='/subscriptions/s/resourceGroups/managed/providers/Microsoft.Insights/dataCollectionRules/native'}}}
        return @{properties=@{references=@{applicationInsights=@(@{resourceId='/foreign'})}}}
    }
    $refused=$false
    try {Set-DemoInsightsPublisher @{subscriptionId='s'} @{insightsId='/expected'}}
    catch {$refused=$_.Exception.Message -like '*does not reference this demo*'}
    if(-not $refused){throw 'Publisher grant must refuse a DCR not linked to the exact component.'}
}
$script:Checks += 3
& {
    function Import-Module {}
    function Read-DemoConfig { return $c }
    function Get-DemoState {
        return @{gatewayId='/demo/gateway';resourceGroupId='/demo';logAnalyticsId='/demo/logs';projects=@{};workbookName='w'}
    }
    function Invoke-DemoAz {
        param($Arguments)
        if ($Arguments[0] -eq 'deployment') { return @() }
        if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'list') { return @(@{id='/demo/foreign-resource'}) }
        throw 'Unexpected Azure command during the cleanup refusal test.'
    }
    Assert-Throws { & (Join-Path $root 'scripts\cleanup.ps1') -ConfigPath 'synthetic' -WhatIf } `
        'Cleanup must refuse a group containing unowned resources, even with valid ownership markers.' 'Group contains 1 unexpected resource'
    function Invoke-DemoAz {
        param($Arguments)
        if ($Arguments[0] -eq 'deployment') { return @() }
        return @(@{id="/demo/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/Failure Anomalies - $($c.gatewayName)-insights"})
    }
    function Get-DemoArm {
        return @{properties=@{detector=@{id='FailureAnomaliesDetector'};scope=@('/another/component')}}
    }
    Assert-Throws { & (Join-Path $root 'scripts\cleanup.ps1') -ConfigPath 'synthetic' -WhatIf } `
        'The expected alert name must not authorize deletion of an alert targeting another component.' 'scoped exclusively'
}

foreach ($case in @(
    @{status=503;body='{"error":{"code":"synthetic_provider_failure","message":"not a real backend"}}';completion=$false;errorCode='synthetic_provider_failure'},
    @{status=503;body='';completion=$false;errorCode=$null},
    @{status=503;body='Synthetic non-JSON upstream failure';completion=$false;errorCode=$null},
    @{status=200;body='null';completion=$false;errorCode=$null},
    @{status=200;body='{"choices":[{"message":{"content":""}}]}';completion=$false;errorCode=$null},
    @{status=200;body='{"choices":[{"message":{"content":"OK"}}],"usage":{"total_tokens":12}}';completion=$true;errorCode=$null}
)) {
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$server = [PowerShell]::Create()
$null = $server.AddScript({
    param($Listener,$Status,$Body)
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(15)
    while (-not $Listener.Pending()) {
        if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Local HTTP test timed out.' }
        Start-Sleep -Milliseconds 10
    }
    $connection=$Listener.AcceptTcpClient()
    try {
        $stream=$connection.GetStream()
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,1024,$true)
        $headers=[Collections.Generic.List[string]]::new()
        while (($line=$reader.ReadLine()) -ne '') { $headers.Add($line) }
        $length=[int](($headers | Where-Object { $_ -like 'Content-Length:*' }) -split ':',2)[1]
        $buffer=[char[]]::new($length); $read=0
        while($read -lt $length){$count=$reader.Read($buffer,$read,$length-$read);if($count -eq 0){throw 'Truncated request.'};$read+=$count}
        $response="HTTP/1.1 $Status Fixture`r`nContent-Type: application/json`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($Body))`r`nConnection: close`r`n`r`n$Body"
        $bytes=[Text.Encoding]::UTF8.GetBytes($response); $stream.Write($bytes,0,$bytes.Length)
        return @{headers=@($headers);body=(-join $buffer)}
    } finally { $connection.Dispose() }
}).AddArgument($listener).AddArgument($case.status).AddArgument($case.body)
$handle=$server.BeginInvoke()
try {
    $r=Invoke-DemoRequest "http://127.0.0.1:$port/" 'demo-chat' 'synthetic-not-a-credential' A test
    $received=@($server.EndInvoke($handle))[0]
    Assert-True ($r.status -eq $case.status -and $r.completion -eq $case.completion -and $r.errorCode -eq $case.errorCode) 'HTTP failures or empty choices must not turn into successful completions.'
    Assert-True (@($received.headers | Where-Object { $_ -cmatch '^traceparent: 00-[0-9a-f]{32}-[0-9a-f]{16}-01$' }).Count -eq 1) 'A W3C trace context is required.'
    Assert-True (-not ($r | ConvertTo-Json -Depth 10).Contains('synthetic-not-a-credential')) 'Results must not retain bearer credentials.'
    Assert-True (-not $listener.Pending()) 'The client must not retry a failed HTTP request.'
    Assert-True (($received.body | ConvertFrom-Json).stream -eq $false) 'Demo requests must be nonstreaming.'
} finally {
    $listener.Stop()
    $server.Dispose()
}
}
& {
    $fixture = [IO.Path]::GetTempFileName()
    $global:DemoAuthFixture=@{}
    function Import-Module {}
    function Read-DemoConfig { return @{gatewayName='demo';subscriptionId='s';resourceGroupName='r'} }
    function Get-DemoState { return @{resourceGroupId='/subscriptions/s/resourceGroups/r'} }
    function Get-DemoArm { return @{properties=@{configuration=@{ingress=@{fqdn='demo-console.test.azurecontainerapps.io'}}}} }
    function az { $global:LASTEXITCODE=0; return 'MAINTENANCE_READY' }
    function Invoke-DemoAz {
        param($Arguments)
        if ($Arguments[0] -eq 'account') { return 'tenant' }
        if ($Arguments[0] -eq 'ad') {
            if ($Arguments[1] -eq 'signed-in-user') { return 'user' }
            if ($Arguments[1] -eq 'sp') { return @{id='owned-service-principal'} }
            if ($Arguments[2] -eq 'owner') { return @{id='user'} }
            if ($Arguments[2] -eq 'show') {
                return @{id='object';appId='client';displayName='demo-console';signInAudience='AzureADMyOrg'
                    passwordCredentials=@(
                        @{keyId='current-key';displayName='console-easy-auth';endDateTime=$global:DemoAuthFixture.currentExpiry},
                        @{keyId='unrelated-key';displayName='console-easy-auth';endDateTime=[DateTimeOffset]::UtcNow.AddDays(20).ToString('o')}
                    )}
            }
        }
        if ($Arguments[0] -eq 'rest') {
            $url=$Arguments[$Arguments.IndexOf('--url')+1]
            if ($url -like '*/listSecrets?*') {
                return @{value=@(@{name='console-auth-client-secret';value='synthetic-current-credential'})}
            }
            if ($url -like '*/addPassword') {
                $global:DemoAuthFixture.passwordAdds++
                return @{keyId='replacement-key';secretText='synthetic-replacement-credential'}
            }
            if ($Arguments -contains 'patch') { return }
        }
        if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'show') {
            return @{properties=@{parameters=@{}}}
        }
        if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'validate') { throw 'Stop synthetic validation' }
        throw 'Unexpected Azure command during the authentication credential test.'
    }
    try {
        foreach ($expired in @($true,$false)) {
            @{consoleAuthApplicationObjectId='object';consoleAuthCredentialKeyId='current-key'} |
                ConvertTo-Json | Set-Content -LiteralPath $fixture
            $global:DemoAuthFixture.passwordAdds=0
            $global:DemoAuthFixture.currentExpiry=[DateTimeOffset]::UtcNow.AddDays($(if($expired){-1}else{20})).ToString('o')
            $observed=$null
            try { & (Join-Path $root 'scripts\enable-console-auth.ps1') -ConfigPath $fixture }
            catch { $observed=$_.Exception.Message }
            Assert-True ($observed -ceq 'Stop synthetic validation') `
                "Synthetic authentication must stop before deployment, not: $observed"
            Assert-True ($global:DemoAuthFixture.passwordAdds -eq $(if($expired){1}else{0})) `
                'Credential reuse must bind to the deployed key, not another unexpired application credential.'
            $saved=Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
            Assert-True ($saved.consoleAuthCredentialKeyId -ceq 'current-key') `
                'A failed deployment must not mark an uninstalled replacement credential as current.'
        }
    } finally {
        Remove-Item -LiteralPath $fixture -Force
        Remove-Variable -Name DemoAuthFixture -Scope Global
    }
}
Write-Host "$script:Checks local checks passed. Synthetic fixtures are not Azure evidence."
