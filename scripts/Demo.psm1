#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot
$script:ApiVersion = '2026-11-01'

function Read-DemoConfig {
    param([Parameter(Mandatory)][string]$Path)
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($c.ContainsKey('provisionDemoCallers') -and $c.provisionDemoCallers -isnot [bool]) {
        throw 'provisionDemoCallers must be a JSON boolean.'
    }
    $managed = $c.ContainsKey('provisionDemoCallers') -and $c.provisionDemoCallers
    $required = @('subscriptionId', 'resourceGroupName', 'location', 'secondaryLocation', 'monitoringLocation',
        'gatewayName', 'gatewaySku', 'modelName', 'modelVersion', 'deploymentName', 'modelSku',
        'modelCapacity')
    if (-not $managed) { $required += @('teamAObjectId','teamBObjectId') }
    foreach ($key in $required) {
        if (-not $c.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$c[$key]) -or [string]$c[$key] -match '[<>]') {
            throw "Supply an explicit $key in the local config."
        }
    }
    $guidKeys = @('subscriptionId')
    if (-not $managed) { $guidKeys += @('teamAObjectId','teamBObjectId') }
    foreach ($key in $guidKeys) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($c[$key], [ref]$id) -or $id -eq [guid]::Empty) { throw "$key must be a nonempty GUID." }
    }
    if (-not $managed -and $c.teamAObjectId -eq $c.teamBObjectId) { throw 'Teams A and B require distinct workload identities.' }
    if ($managed) {
        foreach ($key in @('teamAObjectId','teamBObjectId')) {
            if ($c.ContainsKey($key) -and $c[$key]) { throw 'Do not combine external caller IDs with provisionDemoCallers.' }
        }
    }
    if ($c.resourceGroupName -cnotmatch '^rg-aigw-demo-[a-z0-9-]+$') { throw 'Use a dedicated rg-aigw-demo-* group.' }
    if ($c.gatewayName -cnotmatch '^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$') { throw 'Invalid gateway name.' }
    if ($c.gatewaySku -cne 'Standard') { throw 'The native AI Gateway resource currently requires the Standard SKU.' }
    if ([int]$c.modelCapacity -lt 1) { throw 'modelCapacity must be positive.' }
    return $c
}

function Invoke-DemoAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $text = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE): $($Arguments[0..([Math]::Min(1,$Arguments.Count-1))] -join ' ')." }
    if ($text) { return ($text -join "`n" | ConvertFrom-Json -AsHashtable) }
}

function Get-DemoIds {
    param([hashtable]$Config)
    $group = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)"
    $gateway = "$group/providers/Microsoft.ApiManagement/aigateways/$($Config.gatewayName)"
    return @{ group = $group; gateway = $gateway; workspace = "$gateway/workspaces/default" }
}

function Get-DemoArm {
    param([string]$Id, [string]$ApiVersion = $script:ApiVersion)
    if ($Id -notmatch '^/subscriptions/([0-9a-f-]+)/') { throw 'Expected a subscription-scoped ARM resource ID.' }
    return Invoke-DemoAz @('rest', '--subscription', $Matches[1], '--method', 'get', '--url', "https://management.azure.com${Id}?api-version=$ApiVersion")
}

function Get-DemoArmEnvelope {
    param([string]$Id)
    if ($Id -notmatch '^/subscriptions/([0-9a-f-]+)/') { throw 'Expected a subscription-scoped ARM resource ID.' }
    $credentials = Invoke-DemoAz @('account', 'get-access-token', '--subscription', $Matches[1], '--resource', 'https://management.azure.com/')
    $response = Invoke-WebRequest -Method Get -Uri "https://management.azure.com${Id}?api-version=$script:ApiVersion" `
        -Headers @{ Authorization = "Bearer $($credentials.accessToken)" } -SkipHttpErrorCheck
    if ($response.StatusCode -ne 200) { throw "ARM GET failed HTTP $($response.StatusCode) for $Id." }
    $etag = [string]($response.Headers.ETag | Select-Object -First 1)
    if (-not $etag) { throw "Missing HTTP ETag on $Id; refusing an unguarded update." }
    return @{ body = ($response.Content | ConvertFrom-Json -AsHashtable); etag = $etag }
}

function Set-DemoInsightsPublisher {
    param([hashtable]$Config, [hashtable]$State)
    $insights = Get-DemoArm $State.insightsId '2020-02-02-preview'
    $ruleId = [string]$insights.properties.DataCollectionRuleResourceId
    if (-not $ruleId.StartsWith("/subscriptions/$($Config.subscriptionId)/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Application Insights returned an unexpected managed DCR subscription.'
    }
    $rule = Get-DemoArm $ruleId '2024-03-11'
    if (@($rule.properties.references.applicationInsights | Where-Object resourceId -IEQ $State.insightsId).Count -ne 1) {
        throw 'The managed DCR does not reference this demo Application Insights component.'
    }
    $gateway = Get-DemoArm $State.gatewayId
    $role = "/subscriptions/$($Config.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"
    $assignments = (Get-DemoArm "$ruleId/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value
    $matching = @($assignments | Where-Object {
        $_.properties.principalId -ieq $gateway.identity.principalId -and $_.properties.roleDefinitionId -ieq $role -and
        $_.properties.scope -ieq $ruleId
    })
    if (-not $matching.Count) {
        $file = [IO.Path]::GetTempFileName()
        try {
            @{properties=@{principalId=$gateway.identity.principalId;principalType='ServicePrincipal';roleDefinitionId=$role}} |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file
            # Managed RGs deny ARM deployment writes, but explicitly permit role-assignment writes.
            $assignmentId = "$ruleId/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
            $null = Invoke-DemoAz @('rest','--subscription',$Config.subscriptionId,'--method','put',
                '--url',"https://management.azure.com${assignmentId}?api-version=2022-04-01",'--body',"@$file")
            $read = Get-DemoArm $assignmentId '2022-04-01'
            if ($read.properties.principalId -ine $gateway.identity.principalId -or $read.properties.scope -ine $ruleId) {
                throw 'Application Insights publisher role read-back mismatch.'
            }
        } finally { Remove-Item -LiteralPath $file -Force }
    }
}

function Test-DemoSubset {
    param($Expected, $Actual)
    if ($null -eq $Expected) { return $null -eq $Actual }
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($key in $Expected.Keys) {
            if ($key -eq 'policies' -and $Expected[$key] -is [array] -and $Expected[$key].Count -eq 0 -and -not $Actual.Contains($key)) { continue }
            if ($key -eq 'id' -and -not $Actual.Contains($key) -and $Expected.Contains('type') -and
                $Expected.type -in @('tokenLimit','costLimit') -and $Expected.id -like 'demo-*') { continue }
            if (-not $Actual.Contains($key) -or -not (Test-DemoSubset $Expected[$key] $Actual[$key])) { return $false }
        }
        return $true
    }
    if ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Expected.Count -ne $Actual.Count) { return $false }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            if (-not (Test-DemoSubset $Expected[$i] $Actual[$i])) { return $false }
        }
        return $true
    }
    return $Expected -ceq $Actual
}

function Set-DemoArmProperties {
    param([string]$Id, [hashtable]$Properties, [ValidateSet('patch','put')][string]$Method = 'patch', [hashtable]$Current)
    if (-not $Current) { $Current = Get-DemoArmEnvelope $Id }
    if (Test-DemoSubset $Properties $current.body.properties) { return }
    $file = [IO.Path]::GetTempFileName()
    try {
        @{ properties = $Properties } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $file
        $null = Invoke-DemoAz @('rest', '--subscription', ($Id -split '/')[2], '--method', $Method, '--url', "https://management.azure.com${Id}?api-version=$script:ApiVersion",
            '--headers', "If-Match=$($current.etag)", '--body', "@$file")
        for ($i = 0; $i -lt 30; $i++) {
            $read = Get-DemoArm $Id
            if ($read.properties.ContainsKey('provisioningState') -and $read.properties.provisioningState -in @('Failed', 'Canceled')) {
                throw "Configuration failed for $Id."
            }
            if (Test-DemoSubset $Properties $read.properties) { return }
            Start-Sleep -Seconds 2
        }
        throw "Configuration read-back timed out for $Id."
    } finally { Remove-Item -LiteralPath $file -Force }
}

function Assert-DemoGroup {
    param([hashtable]$Config)
    $group = Invoke-DemoAz @('group', 'show', '--subscription', $Config.subscriptionId, '--name', $Config.resourceGroupName)
    $ids = Get-DemoIds $Config
    if ($group.id -ine $ids.group -or $group.tags.purpose -ne 'ai-gateway-demo' -or
        $group.tags.managedBy -ne 'azure-ai-gateway-demo' -or $group.tags.demoGateway -cne $Config.gatewayName) {
        throw 'Dedicated demo group ownership markers do not match. No mutation allowed.'
    }
}

function Get-DemoState {
    param([hashtable]$Config)
    Assert-DemoGroup $Config
    $state = if ($env:DEMO_STATE_PATH) {
        Get-Content -LiteralPath $env:DEMO_STATE_PATH -Raw | ConvertFrom-Json -AsHashtable
    } else {
        Invoke-DemoAz @('deployment', 'sub', 'show', '--subscription', $Config.subscriptionId,
            '--name', "demo-$($Config.gatewayName)", '--query', 'properties.outputs.demo.value')
    }
    $ids = Get-DemoIds $Config
    if (-not $state -or $state.gatewayId -ine $ids.gateway -or $state.resourceGroupId -ine $ids.group) {
        throw 'Missing or mismatched subscription deployment outputs.'
    }
    if ($Config.ContainsKey('provisionDemoCallers') -and $Config.provisionDemoCallers) {
        if (-not $state.callersProvisioned) { throw 'The deployed environment did not provision dedicated callers.' }
        foreach ($team in @('A','B')) {
            $identity = $state.callerIdentities[$team]
            $expectedId = "$($ids.group)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($Config.gatewayName)-team-$($team.ToLowerInvariant())"
            if ($identity.id -ine $expectedId -or $identity.principalId -ine $state["team${team}ObjectId"]) {
                throw 'Dedicated caller identity outputs do not match this demo.'
            }
            $Config["team${team}ObjectId"] = $identity.principalId
        }
    }
    if ($state.teamAObjectId -ine $Config.teamAObjectId -or $state.teamBObjectId -ine $Config.teamBObjectId) {
        throw 'Configuration caller identities differ from the deployed identities.'
    }
    return $state
}

function Get-DemoRuntimeEndpoint {
    param([hashtable]$State)
    if ($State.hostname -cnotmatch '^[a-zA-Z0-9.-]+$') { throw 'Invalid service-assigned gateway hostname.' }
    $paths = @()
    $first = $true
    foreach ($alias in @('demo-chat','demo-alt')) {
        $resource = Get-DemoArm "$($State.workspaceId)/aliases/$alias"
        $supported = @($resource.properties.gatewayEndpoints | Where-Object {
            $url = $null
            $_.api -ceq 'v1/chat/completions' -and [uri]::TryCreate($_.url, [UriKind]::Absolute, [ref]$url) -and
                $url.Scheme -eq 'https' -and $url.Host -ieq $State.hostname -and $url.IsDefaultPort -and
                -not $url.UserInfo -and -not $url.Query -and -not $url.Fragment -and
                $url.AbsolutePath -cmatch '^/default/models/[a-zA-Z0-9/_-]+/chat/completions$' -and
                $url.AbsolutePath -notmatch '//'
        } | ForEach-Object url)
        $paths = if ($first) { $supported } else { @($paths | Where-Object { $_ -cin $supported }) }
        $first = $false
    }
    $common = @($paths | Select-Object -Unique)
    if ($common.Count -ne 1) { throw 'Both aliases must advertise one unambiguous common Chat Completions path.' }
    return $common[0]
}

function Reset-DemoLabFaults {
    param([hashtable]$State)
    foreach ($backend in @(1,2)) {
        $id = "$($State.workspaceId)/modelProviders/backend-$backend/models/demo-model"
        $resource = Get-DemoArm $id
        $mappings = @($resource.properties.endpoints)
        if ($mappings.Count -ne 1 -or $mappings[0].api -ne 'v1/chat/completions' -or
            $mappings[0].path -notin @('/openai/v1/chat/completions','/demo-injected-unavailable')) {
            throw 'Unexpected model mapping. Reset refuses to overwrite a non-demo endpoint configuration.'
        }
        Set-DemoArmProperties $id @{ endpoints=@(@{api='v1/chat/completions';path='/openai/v1/chat/completions'}) }
    }
}

function Set-DemoProfile {
    param([hashtable]$Config, [ValidateSet('baseline','weighted-routing','failover','token-rate','token-quota','cost-limit')][string]$Profile)
    Assert-DemoGroup $Config
    $ids = Get-DemoIds $Config
    $json = Get-Content -LiteralPath (Join-Path $script:Root "config\profiles\$Profile.json") -Raw
    $p = $json.Replace('__TEAM_A_OBJECT_ID__',$Config.teamAObjectId) | ConvertFrom-Json -AsHashtable
    $workspace = Get-DemoArmEnvelope $ids.workspace
    $existingPolicies = if ($workspace.body.properties.ContainsKey('policies')) { @($workspace.body.properties.policies) } else { @() }
    $knownPolicies = foreach ($file in Get-ChildItem (Join-Path $script:Root 'config\profiles') -Filter '*.json') {
        $profileJson = (Get-Content -LiteralPath $file.FullName -Raw).Replace('__TEAM_A_OBJECT_ID__',$Config.teamAObjectId)
        ($profileJson | ConvertFrom-Json -AsHashtable).policies
    }
    foreach ($existing in $existingPolicies) {
        $known = $false
        foreach ($candidate in $knownPolicies) {
            $expectedPolicy = $candidate.Clone()
            $actualPolicy = $existing.Clone()
            if ($actualPolicy.ContainsKey('id') -and $actualPolicy.id -cne $expectedPolicy.id) { continue }
            $expectedPolicy.Remove('id')
            $actualPolicy.Remove('id')
            if ((Test-DemoSubset $expectedPolicy $actualPolicy) -and (Test-DemoSubset $actualPolicy $expectedPolicy)) {
                $known = $true
                break
            }
        }
        if (-not $known) { throw 'Unexpected workspace policies: refusing to replace another configuration.' }
    }
    Set-DemoArmProperties $ids.workspace @{ policies = @($p.policies) } -Current $workspace
    foreach ($alias in @('demo-chat','demo-alt')) {
        $targets = for ($i=0; $i -lt 2; $i++) {
            $priority = $p.backends[$i].priority
            if ($alias -eq 'demo-alt' -and $Profile -ne 'weighted-routing') { $priority = 1 - $priority }
            @{ resourceId = "$($ids.workspace)/modelProviders/backend-$($i+1)/models/demo-model"
               priority = $priority; weight = $p.backends[$i].weight }
        }
        $properties = @{
            aliasName = $alias; backendModels = @($targets); selectionOrder = @('priority')
            failures = @($p.failures); policies = @()
        }
        if ($p.failures.Count) { $properties.maxRetryAttempts = $p.maxRetryAttempts }
        Set-DemoArmProperties "$($ids.workspace)/aliases/$alias" $properties -Method put
        $read = Get-DemoArm "$($ids.workspace)/aliases/$alias"
        if (-not $p.failures.Count -and $read.properties.ContainsKey('maxRetryAttempts') -and $read.properties.maxRetryAttempts -gt 0) {
            throw 'Alias replacement did not clear the previous attempt budget.'
        }
    }
}

function Get-DemoRequestsQuery {
    param([hashtable]$State)
    if ($State.hostname -cnotmatch '^[a-zA-Z0-9.-]+$' -or
        $State.gatewayId -notmatch '^/subscriptions/[a-f0-9-]+/resourceGroups/[a-zA-Z0-9_-]+/providers/Microsoft.ApiManagement/aigateways/[a-z0-9-]+$' -or
        $State.insightsId -ine "$($State.resourceGroupId)/providers/Microsoft.Insights/components/$(($State.gatewayId -split '/')[-1])-insights") {
        throw 'Unexpected gateway/Insights query scope; refusing KQL interpolation.'
    }
    return (Get-Content (Join-Path $script:Root 'observability\requests.kql') -Raw).
        Replace('__GATEWAY_ID__', $State.gatewayId).
        Replace('__INSIGHTS_ID__', $State.insightsId).
        Replace('__GATEWAY_HOSTNAME__', $State.hostname)
}

function Invoke-DemoQuery {
    param([hashtable]$Config, [hashtable]$State, [string]$Query)
    $file = [IO.Path]::GetTempFileName()
    try {
        @{query=$Query;timespan='PT1H'} | ConvertTo-Json | Set-Content -LiteralPath $file
        $response = Invoke-DemoAz @('rest','--subscription',$Config.subscriptionId,'--method','post',
            '--resource','https://api.loganalytics.io','--url',"https://api.loganalytics.azure.com/v1/workspaces/$($State.logAnalyticsCustomerId)/query",
            '--body',"@$file")
        if ($response.ContainsKey('error') -or $response.tables.Count -ne 1) { throw 'Native telemetry query returned an incomplete or unexpected result.' }
        $table = $response.tables[0]
        foreach ($row in $table.rows) {
            if ($row.Count -ne $table.columns.Count) { throw 'Native telemetry query returned a malformed row.' }
            $record = @{}
            for ($i=0; $i -lt $table.columns.Count; $i++) { $record[$table.columns[$i].name] = $row[$i] }
            $record
        }
    } finally { Remove-Item -LiteralPath $file -Force }
}

function Assert-DemoPricingSeries {
    param([array]$Series)
    if ($Series.Count -eq 0) { throw 'No fresh native cost metric series. Do not send more cost-test traffic.' }
    foreach ($item in $Series) {
        if (-not $item.metric.ContainsKey('azure.ai_gateway.price_missing') -or
            $item.metric['azure.ai_gateway.price_missing'] -cne 'false' -or
            -not [double]::IsFinite([double]$item.value[1]) -or [double]$item.value[1] -le 0) {
            throw 'Missing, zero, or incomplete native pricing. Cost-limit traffic is refused.'
        }
    }
}

function Assert-DemoPricing {
    param([hashtable]$Config, [hashtable]$State, [string]$BaselineEvidencePath)
    if (-not $BaselineEvidencePath) { throw 'Cost-limit requires -BaselineEvidencePath from a native-verified baseline run.' }
    $evidence = Get-Content -LiteralPath $BaselineEvidencePath -Raw | ConvertFrom-Json -AsHashtable
    if ($evidence.scenario -ne 'baseline' -or $evidence.gatewayId -ine $State.gatewayId) { throw 'Pricing baseline belongs to another scenario/gateway.' }
    foreach ($alias in @('demo-chat','demo-alt')) {
        $rows = @($evidence.rows | Where-Object { $_.Alias -eq $alias -and $_.Identity -ieq $Config.teamAObjectId })
        if ($rows.Count -ne 1 -or [double]$rows[0].EstimatedUsd -le 0) {
            throw 'Need fresh nonzero native response cost for A through BOTH baseline backends.'
        }
        $time = if ($rows[0].TimeGenerated -is [datetime]) { [DateTimeOffset]::new($rows[0].TimeGenerated) }
            else { [DateTimeOffset]::Parse($rows[0].TimeGenerated) }
        if ($time -lt [DateTimeOffset]::UtcNow.AddMinutes(-10) -or $time -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) {
            throw 'Native baseline pricing evidence is stale or has a future timestamp.'
        }
    }
    $metrics = Get-DemoArm $State.metricsId '2023-04-03'
    $endpoint = [uri]$metrics.properties.metrics.prometheusQueryEndpoint
    if ($endpoint.Scheme -ne 'https' -or -not $endpoint.Host.EndsWith('.prometheus.monitor.azure.com') -or $endpoint.UserInfo) {
        throw 'Unexpected Azure Monitor query endpoint.'
    }
    $credentials = Invoke-DemoAz @('account','get-access-token','--subscription',$Config.subscriptionId,'--resource','https://prometheus.monitor.azure.com')
    foreach ($alias in @('demo-chat','demo-alt')) {
        $selector = '{__name__="azure.ai_gateway.client.token.cost","microsoft.appresourceid"="' +
            $State.insightsId.ToLowerInvariant() + '","azure.ai_gateway.workspace"="default","azure.ai_gateway.identity.claims.oid"="' +
            $Config.teamAObjectId + '","gen_ai.request.model"="' + $alias + '","gen_ai.token.type"=""}'
        $query = [uri]::EscapeDataString("last_over_time(${selector}[10m])")
        $response = Invoke-WebRequest -Uri "$($endpoint.AbsoluteUri.TrimEnd('/'))/api/v1/query?query=$query" `
            -Headers @{ Authorization="Bearer $($credentials.accessToken)" } -SkipHttpErrorCheck
        if ($response.StatusCode -ne 200) { throw "Native pricing query failed HTTP $($response.StatusCode)." }
        $data = $response.Content | ConvertFrom-Json -AsHashtable
        if ($data.status -ne 'success' -or $data.data.resultType -ne 'vector' -or
            ($data.ContainsKey('warnings') -and $data.warnings.Count)) { throw 'Incomplete native pricing query; traffic refused.' }
        Assert-DemoPricingSeries @($data.data.result)
    }
}

function Get-DemoToken {
    param([ValidateSet('A','B')][string]$Team, [hashtable]$Config)
    $token = [Environment]::GetEnvironmentVariable("DEMO_TEAM_${Team}_TOKEN")
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Set DEMO_TEAM_${Team}_TOKEN in the process environment; never put tokens in config." }
    $parts = $token.Split('.')
    if ($parts.Length -ne 3) { throw "Team $Team token is not a JWT." }
    $base64 = $parts[1].Replace('-', '+').Replace('_', '/')
    $base64 = $base64.PadRight($base64.Length + ((4 - $base64.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json -AsHashtable
    $expected = if ($Team -eq 'A') { $Config.teamAObjectId } else { $Config.teamBObjectId }
    if ($claims.oid -ine $expected -or [long]$claims.exp -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 120 -or
        $claims.aud -notin @('https://ai.gateway.azure.com', 'https://ai.gateway.azure.com/', '18550318-e177-4205-a743-6816d6fcdc3f')) {
        throw "Team $Team token has the wrong identity, audience, or expiry."
    }
    # This is a local mix-up check, not token validation; the target service verifies the signature.
    return $token
}

function Assert-DemoRunBudget {
    param([hashtable]$Config, [int]$Requests, [int]$Attempts = 1, [int]$MaxCompletionTokens = 64)
    foreach ($key in @('inputUsdPerMillion','outputUsdPerMillion','maxRunEstimatedUsd')) {
        if (-not $Config.ContainsKey($key) -or [double]$Config[$key] -le 0 -or
            -not [double]::IsFinite([double]$Config[$key])) { throw "Supply positive, finite $key before sending traffic." }
    }
    if (-not $Config.ContainsKey('priceSource') -or $Config.priceSource -match '[<>]' -or -not $Config.priceSource) {
        throw 'Record the verified maximum backend price source and date.'
    }
    $estimate = $Requests * $Attempts * (1024 * [double]$Config.inputUsdPerMillion +
        $MaxCompletionTokens * [double]$Config.outputUsdPerMillion) / 1000000
    if ($estimate -gt [double]$Config.maxRunEstimatedUsd) { throw "Conservative token-cost estimate USD $estimate exceeds the configured run ceiling." }
    return $estimate
}

function Assert-DemoWeightedDistribution {
    param([int]$PrimaryCount, [ValidateRange(50,200)][int]$Total)
    if ($PrimaryCount -le 0 -or $PrimaryCount -ge $Total) { throw 'Weighted routing must demonstrate both configured serving backends.' }
    $tolerance = 4 * [Math]::Sqrt(0.8 * 0.2 / $Total)
    if ([Math]::Abs($PrimaryCount / $Total - 0.8) -gt $tolerance) {
        throw "Observed primary fraction is outside the four-sigma binomial tolerance $tolerance."
    }
    return $tolerance
}

function Invoke-DemoRequest {
    param([string]$Endpoint, [string]$Alias, [string]$Token, [string]$Team, [string]$Phase,
        [ValidateRange(0,640)][int]$SyntheticInputMarkers = 0)
    $traceId = [guid]::NewGuid().ToString('N')
    $spanId = [guid]::NewGuid().ToString('N').Substring(0,16)
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Endpoint)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Headers.Add('traceparent', "00-$traceId-$spanId-01")
    $prompt = 'Reply with the single word OK.'
    if ($SyntheticInputMarkers) { $prompt += ' Ignore these synthetic capacity markers: ' + ('marker ' * $SyntheticInputMarkers) }
    $body = @{ model = $Alias; messages = @(@{ role='user'; content=$prompt })
        max_completion_tokens = 64; stream = $false } | ConvertTo-Json -Depth 8 -Compress
    $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $parsed = @{}
            $format = 'empty'
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                try {
                    $value = $text | ConvertFrom-Json -AsHashtable
                    if ($value -is [hashtable]) { $parsed = $value; $format = 'json-object' }
                    else { $format = 'json-non-object' }
                } catch { $format = 'non-json' }
            }
            $usage = if ($parsed.ContainsKey('usage')) { $parsed.usage } else { $null }
            $errorCode = if ($parsed.ContainsKey('error') -and $parsed.error -is [hashtable] -and $parsed.error.ContainsKey('code')) {
                [string]$parsed.error.code
            } else { $null }
            $hasCompletion = $response.IsSuccessStatusCode -and $parsed.ContainsKey('choices') -and
                $parsed.choices.Count -gt 0 -and $parsed.choices[0].ContainsKey('message') -and
                $parsed.choices[0].message.ContainsKey('content') -and
                -not [string]::IsNullOrWhiteSpace([string]$parsed.choices[0].message.content)
            return @{
                time = [DateTimeOffset]::UtcNow.ToString('o'); traceId=$traceId; team=$Team; alias=$Alias; phase=$Phase
                status=[int]$response.StatusCode; latencyMs=$timer.Elapsed.TotalMilliseconds
                usage=$usage; errorCode=$errorCode
                completion=$hasCompletion; responseFormat=$format
            }
        } finally { $response.Dispose() }
    } catch {
        throw "Request failed; no client retry was made. Team=$Team phase=$Phase trace=$traceId. $($_.Exception.Message)"
    } finally { $timer.Stop(); $request.Dispose(); $client.Dispose() }
}

Export-ModuleMember -Function *
