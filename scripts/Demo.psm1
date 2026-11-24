#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot
$script:ApiVersion = '2026-11-01'

function Read-DemoConfig {
    param([Parameter(Mandatory)][string]$Path)
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @('subscriptionId', 'resourceGroupName', 'location', 'secondaryLocation', 'monitoringLocation',
        'gatewayName', 'gatewaySku', 'modelName', 'modelVersion', 'deploymentName', 'modelSku',
        'modelCapacity', 'teamAObjectId', 'teamBObjectId')) {
        if (-not $c.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$c[$key]) -or [string]$c[$key] -match '[<>]') {
            throw "Supply an explicit $key in the local config."
        }
    }
    foreach ($key in @('subscriptionId', 'teamAObjectId', 'teamBObjectId')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($c[$key], [ref]$id) -or $id -eq [guid]::Empty) { throw "$key must be a nonempty GUID." }
    }
    if ($c.teamAObjectId -eq $c.teamBObjectId) { throw 'Teams A and B require distinct workload identities.' }
    if ($c.resourceGroupName -cnotmatch '^rg-aigw-demo-[a-z0-9-]+$') { throw 'Use a dedicated rg-aigw-demo-* group.' }
    if ($c.gatewayName -cnotmatch '^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$') { throw 'Invalid gateway name.' }
    if ($c.gatewaySku -cnotin @('Standard', 'Premium', 'Consumption')) { throw 'Unsupported gateway SKU selector.' }
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

function Test-DemoSubset {
    param($Expected, $Actual)
    if ($null -eq $Expected) { return $null -eq $Actual }
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($key in $Expected.Keys) {
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
    param([string]$Id, [hashtable]$Properties)
    $current = Get-DemoArmEnvelope $Id
    if (Test-DemoSubset $Properties $current.body.properties) { return }
    $file = [IO.Path]::GetTempFileName()
    try {
        @{ properties = $Properties } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $file
        $null = Invoke-DemoAz @('rest', '--subscription', ($Id -split '/')[2], '--method', 'patch', '--url', "https://management.azure.com${Id}?api-version=$script:ApiVersion",
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
    $state = Invoke-DemoAz @('deployment', 'sub', 'show', '--subscription', $Config.subscriptionId,
        '--name', "demo-$($Config.gatewayName)", '--query', 'properties.outputs.demo.value')
    $ids = Get-DemoIds $Config
    if (-not $state -or $state.gatewayId -ine $ids.gateway -or $state.resourceGroupId -ine $ids.group) {
        throw 'Missing or mismatched subscription deployment outputs.'
    }
    if ($state.teamAObjectId -ine $Config.teamAObjectId -or $state.teamBObjectId -ine $Config.teamBObjectId) {
        throw 'Configuration caller identities differ from the deployed identities.'
    }
    return $state
}

function Get-DemoRuntimeEndpoint {
    param([hashtable]$State)
    $paths = @()
    $first = $true
    foreach ($alias in @('demo-chat','demo-alt')) {
        $resource = Get-DemoArm "$($State.workspaceId)/aliases/$alias"
        $supported = @($resource.properties.supportedEndpoints | Where-Object {
            $_ -cmatch '^/[a-zA-Z0-9/_-]+/chat/completions$' -and $_ -notmatch '//'
        })
        $paths = if ($first) { $supported } else { @($paths | Where-Object { $_ -cin $supported }) }
        $first = $false
    }
    $common = @($paths | Select-Object -Unique)
    if ($common.Count -ne 1) { throw 'Both aliases must advertise one unambiguous common Chat Completions path.' }
    if ($State.hostname -cnotmatch '^[a-zA-Z0-9.-]+$') { throw 'Invalid service-assigned gateway hostname.' }
    return "https://$($State.hostname)/default/models$($common[0])"
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
    $workspace = Get-DemoArm $ids.workspace
    $existingPolicies = if ($workspace.properties.ContainsKey('policies')) { @($workspace.properties.policies) } else { @() }
    $foreign = @($existingPolicies | Where-Object { -not $_.ContainsKey('id') -or $_.id -notlike 'demo-*' })
    if ($foreign.Count) { throw 'Unexpected workspace policies: refusing to replace another configuration.' }
    Set-DemoArmProperties $ids.workspace @{ policies = @($p.policies) }
    foreach ($alias in @('demo-chat','demo-alt')) {
        $targets = for ($i=0; $i -lt 2; $i++) {
            $priority = $p.backends[$i].priority
            if ($alias -eq 'demo-alt' -and $Profile -ne 'weighted-routing') { $priority = 1 - $priority }
            @{ resourceId = "$($ids.workspace)/modelProviders/backend-$($i+1)/models/demo-model"
               priority = $priority; weight = $p.backends[$i].weight }
        }
        Set-DemoArmProperties "$($ids.workspace)/aliases/$alias" @{
            aliasName = $alias; backendModels = @($targets); selectionOrder = @('priority')
            maxRetryAttempts = $p.maxRetryAttempts; failures = @($p.failures); policies = @()
        }
    }
}

function Invoke-DemoQuery {
    param([hashtable]$Config, [hashtable]$State, [string]$Query)
    return Invoke-DemoAz @('monitor','log-analytics','query','--subscription',$Config.subscriptionId,
        '--workspace',$State.logAnalyticsCustomerId,'--analytics-query',$Query,'--timespan','PT1H')
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
    # This is a local mix-up check, not token validation; the gateway verifies the signature.
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

function Invoke-DemoRequest {
    param([string]$Endpoint, [string]$Alias, [string]$Token, [string]$Team, [string]$Phase)
    $traceId = [guid]::NewGuid().ToString('N')
    $spanId = [guid]::NewGuid().ToString('N').Substring(0,16)
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Endpoint)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Headers.Add('traceparent', "00-$traceId-$spanId-01")
    $body = @{ model = $Alias; messages = @(@{ role='user'; content='Reply with the single word OK.' })
        max_completion_tokens = 64; stream = $false } | ConvertTo-Json -Depth 8 -Compress
    $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $parsed = $null
            try { $parsed = $text | ConvertFrom-Json -AsHashtable }
            catch { throw "Non-JSON gateway response, HTTP $([int]$response.StatusCode), trace $traceId." }
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
                completion=$hasCompletion
            }
        } finally { $response.Dispose() }
    } catch {
        throw "Request failed; no client retry was made. Team=$Team phase=$Phase trace=$traceId. $($_.Exception.Message)"
    } finally { $timer.Stop(); $request.Dispose(); $client.Dispose() }
}

Export-ModuleMember -Function *
