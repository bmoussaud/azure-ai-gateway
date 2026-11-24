#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$ApplicationObjectId,
    [string]$Image
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Demo.psm1') -Force
$config = Read-DemoConfig $ConfigPath
$state = Get-DemoState $config
$name = "$($config.gatewayName)-console"
$appId = "$($state.resourceGroupId)/providers/Microsoft.App/containerApps/$name"
$app = Get-DemoArm $appId '2024-03-01'
$maintenance = & az containerapp exec --subscription $config.subscriptionId `
    --resource-group $config.resourceGroupName --name $name `
    --command 'python3 /app/console/operate.py maintenance' --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0 -or ($maintenance -join "`n") -notmatch 'MAINTENANCE_READY') {
    throw 'Console maintenance was not confirmed; authentication deployment refused.'
}
$origin = "https://$($app.properties.configuration.ingress.fqdn)"
$tenant = Invoke-DemoAz @('account','show','--subscription',$config.subscriptionId,'--query','tenantId')
$userId = Invoke-DemoAz @('ad','signed-in-user','show','--query','id')
$original = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
if (-not $ApplicationObjectId -and $original.ContainsKey('consoleAuthApplicationObjectId')) {
    $ApplicationObjectId = $original.consoleAuthApplicationObjectId
}
if ($ApplicationObjectId) {
    $registration = Invoke-DemoAz @('ad','app','show','--id',$ApplicationObjectId)
    if ($registration.displayName -cne $name -or $registration.signInAudience -cne 'AzureADMyOrg') {
        throw 'Authentication registration is not the expected single-tenant demo application.'
    }
} else {
    $registration = Invoke-DemoAz @('ad','app','create','--display-name',$name,
        '--sign-in-audience','AzureADMyOrg','--web-redirect-uris',"$origin/.auth/login/aad/callback",
        '--enable-id-token-issuance','true')
}
$owners = @(Invoke-DemoAz @('ad','app','owner','list','--id',$registration.id))
if ($userId -notin @($owners | ForEach-Object { $_.id })) {
    throw 'The signed-in operator must own the dedicated authentication registration.'
}
$original.consoleAuthApplicationObjectId = $registration.id
$original.consoleAuthClientId = $registration.appId
$original.consoleAuthUserPrincipalId = $userId
$original.consoleAuthTenantId = $tenant
$original.consoleUrl = $origin
$original | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath
$file = [IO.Path]::GetTempFileName()
$credential = $null
$newCredentialKeyId = $null
try {
    @{
        identifierUris=@("api://$($registration.appId)")
        api=@{requestedAccessTokenVersion=2}
        web=@{redirectUris=@("$origin/.auth/login/aad/callback")
            implicitGrantSettings=@{enableIdTokenIssuance=$true;enableAccessTokenIssuance=$false}}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file
    $null = Invoke-DemoAz @('rest','--method','patch','--url',"https://graph.microsoft.com/v1.0/applications/$($registration.id)",
        '--body',"@$file")
    $principals = @(Invoke-DemoAz @('ad','sp','list','--filter',"appId eq '$($registration.appId)'"))
    if ($principals.Count -eq 0) { $null = Invoke-DemoAz @('ad','sp','create','--id',$registration.appId) }
    elseif ($principals.Count -ne 1) { throw 'Authentication service principal is ambiguous.' }
    $secrets = Invoke-DemoAz @('rest','--method','post','--url',
        "https://management.azure.com$appId/listSecrets?api-version=2024-03-01")
    $existing = @($secrets.value | Where-Object name -CEQ 'console-auth-client-secret')
    $credentials = @($registration.passwordCredentials)
    if (-not $original.ContainsKey('consoleAuthCredentialKeyId') -and $credentials.Count -eq 1 -and
        $credentials[0].displayName -ceq 'console-easy-auth' -and $existing.Count -eq 1) {
        $original.consoleAuthCredentialKeyId = $credentials[0].keyId
    }
    $valid = @($credentials | Where-Object {
        $original.ContainsKey('consoleAuthCredentialKeyId') -and
        $_.keyId -ceq $original.consoleAuthCredentialKeyId -and
        $_.displayName -ceq 'console-easy-auth' -and [DateTimeOffset]$_.endDateTime -gt [DateTimeOffset]::UtcNow.AddDays(2)
    })
    if ($existing.Count -eq 1 -and $valid.Count -eq 1) { $secret = $existing[0].value }
    else {
        @{passwordCredential=@{displayName='console-easy-auth'
            endDateTime=[DateTimeOffset]::UtcNow.AddDays(30).ToString('yyyy-MM-ddTHH:mm:ssZ')}} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file
        $credential = Invoke-DemoAz @('rest','--method','post',
            '--url',"https://graph.microsoft.com/v1.0/applications/$($registration.id)/addPassword",
            '--body',"@$file")
        $secret = $credential.secretText
        $newCredentialKeyId = $credential.keyId
    }
    if ([string]::IsNullOrWhiteSpace($secret)) { throw 'No browser sign-in credential is available.' }
    $deployment = Invoke-DemoAz @('deployment','group','show','--subscription',$config.subscriptionId,
        '--resource-group',$config.resourceGroupName,'--name',$name)
    $parameters = $deployment.properties.parameters
    $parameters.deployApp = @{value=$true}
    $parameters.authMode = @{value='entra'}
    $parameters.authTenantId = @{value=$tenant}
    $parameters.authClientId = @{value=$registration.appId}
    $parameters.authUserPrincipalId = @{value=$userId}
    $parameters.authClientSecret = @{value=$secret}
    $parameters.releaseIpRestriction = @{value=$false}
    $parameters.demoConfig = @{value=($original | ConvertTo-Json -Depth 20 -Compress)}
    if ($Image) {
        if ($Image -cnotmatch '^aigw[a-z0-9]{13}\.azurecr\.io/console@sha256:[a-f0-9]{64}$') {
            throw 'Supply an immutable console image in the dedicated registry.'
        }
        $parameters.image = @{value=$Image}
    }
    $common = @('--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroupName,
        '--name',$name,'--template-file',(Join-Path (Split-Path $PSScriptRoot) 'infra\console.bicep'),
        '--parameters',"@$file")
    @{parameters=$parameters} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file
    $null = Invoke-DemoAz (@('deployment','group','validate') + $common)
    $null = Invoke-DemoAz (@('deployment','group','what-if','--no-pretty-print') + $common)
    $live = Invoke-DemoAz (@('deployment','group','create') + $common)
    if ($credential) { $original.consoleAuthCredentialKeyId = $newCredentialKeyId }
    $original | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath
    $auth = Get-DemoArm "$appId/authConfigs/current" '2024-03-01'
    $aad = $auth.properties.identityProviders.azureActiveDirectory
    $expected = @($userId, $live.properties.outputs.operatorPrincipalId.value)
    $actual = @($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities)
    $expectedApps = @($registration.appId, $live.properties.outputs.operatorClientId.value)
    $actualApps = @($aad.validation.defaultAuthorizationPolicy.allowedApplications)
    if (-not $auth.properties.platform.enabled -or
        -not $auth.properties.httpSettings.requireHttps -or -not $aad.enabled -or
        $auth.properties.globalValidation.unauthenticatedClientAction -cne 'RedirectToLoginPage' -or
        @($auth.properties.globalValidation.excludedPaths).Count -ne 1 -or
        $auth.properties.globalValidation.excludedPaths[0] -cne '/health' -or
        $aad.registration.clientId -cne $registration.appId -or
        $aad.registration.openIdIssuer -cne "https://login.microsoftonline.com/$tenant/v2.0" -or
        @($auth.properties.login.allowedExternalRedirectUrls).Count -ne 1 -or
        $auth.properties.login.allowedExternalRedirectUrls[0] -cne $origin -or
        $actualApps.Count -ne 2 -or @(Compare-Object $actualApps $expectedApps).Count -or
        $actual.Count -ne 2 -or @(Compare-Object $actual $expected).Count) {
        throw 'Mandatory exact-principal Entra authentication was not confirmed; ingress remains IP-restricted.'
    }
    $parameters.releaseIpRestriction.value = $true
    @{parameters=$parameters} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file
    $null = Invoke-DemoAz (@('deployment','group','validate') + $common)
    $null = Invoke-DemoAz (@('deployment','group','what-if','--no-pretty-print') + $common)
    $null = Invoke-DemoAz (@('deployment','group','create') + $common)
    $deployed = Get-DemoArm $appId '2024-03-01'
    if (@($deployed.properties.configuration.ingress.ipSecurityRestrictions).Count) {
        throw 'Entra is enabled, but the unreliable IP restriction is still present.'
    }
    @{url=$origin;loginUrl="$origin/.auth/login/aad";appName=$name;image=$parameters.image.value;access='Entra: exact user and operator managed identity';
        deployedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json |
        Set-Content (Join-Path (Split-Path $PSScriptRoot) '.demo\console-deployment.json')
    Write-Host "Protected console: $origin/.auth/login/aad (Entra sign-in; runtime acceptance still required)."
} finally {
    Remove-Item -LiteralPath $file -Force
    $secret = $null
    $credential = $null
}
