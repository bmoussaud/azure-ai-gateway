# Operator guide

## Acceptance status

The dedicated Azure foundation was deployed on 2026-11-24 in East US 2: Standard gateway, two GPT-6 Sol `2026-09-22` GlobalStandard backends, managed callers A/B, native OTLP monitoring and Workbook. Native records verified the four baseline calls, 40/50 primary selections in the weighted run, complete failover/exclusion/all-down/recovery, and minute/hour token rejection across both aliases while B continued. All three deployed Workbook queries executed successfully. Native pricing completeness remains blocked; see the acceptance notes below. Synthetic tests are never gateway results.

Use the [capability matrix](capabilities.md) for the public contracts and remaining uncertainties. The deployment entrypoint is `infra\demo.bicep`, at subscription scope. `infra\main.bicep` is its Foundry backend module, not a standalone gateway deployment.

## 1. Select the dedicated target

### Browser console (Entra-protected HTTPS)

The optional console shows Application A and Application B side by side and runs the same versioned PowerShell scenarios, not a second approximation of gateway behavior:

```powershell
.\scripts\deploy-console.ps1 -ConfigPath .\config\demo.local.json
# Prints the service-assigned HTTPS URL and saves .demo\console-deployment.json.
python -m unittest discover -s .\tests -p test_console.py
# Real HTTPS acceptance: use an authorized bearer only in this process environment.
# Prefer the server-side helper below; never paste credentials into commands or evidence.
.\scripts\verify-console.ps1 -Url '<deployed-console-https-url>'
```

The deployment bootstraps behind an operator IPv4 /32, then `enable-console-auth.ps1` configures native Container Apps Easy Auth. **Entra authentication is mandatory** and its exact-principal allowlist contains only the signed-in deploying user and dedicated operator managed identity. Other tenant users and the A/B application identities cannot operate the console. Only read-only `/health` is excluded. HTTPS, single-tenant issuer, explicit audiences and a server-side client secret are enforced; no directory API permissions are granted. A GET confirms native authentication and the exact allowlist **before** the unreliable NAT-based ingress restriction is removed. Unauthenticated clients are redirected to Entra, not given scenario access.

The operator must be able to create and own this dedicated Entra application registration as well as deploy Azure resources. Directory registration/service-principal/password operations use versioned Graph/Azure CLI contracts because these directory objects are not ARM resources; native authorization is in `infra\console-auth.bicep`. Non-secret registration IDs are saved only in the ignored local configuration. The 30-day browser-login credential is passed through a secure Bicep parameter, stored as a Container Apps secret, never exposed in container environment variables, and removed from the temporary parameter file in `finally`. Re-running `enable-console-auth.ps1` reuses a current secret or rotates one within two days of expiry.

Use the printed `/.auth/login/aad` entry URL for a first visit, then return to the website. A non-browser anonymous request can receive 401 rather than an interactive redirect. The exact console origin is explicitly included in `login.allowedExternalRedirectUrls`: native Easy Auth otherwise rejects browser-cookie POSTs with an empty 403 before they reach the application. This preserves its [CSRF protection](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization#mitigation-of-cross-site-request-forgery), rather than disabling it. The application's own same-origin/CSRF checks remain mandatory.

Browser acceptance on 2026-11-24 completed an actual signed-in HTTPS baseline: two A calls, two B calls, both aliases and both native backends, HTTP 200 and 17 tokens each, four matching native records, strict verification and confirmed automatic baseline restoration. Other scenario engines were already qualified through the CLI; the complete browser scenario sequence was not rerun for this accelerated delivery.

For unattended acceptance without exposing an Azure credential locally or in the browser, run the owned-container helper through authenticated Azure control-plane exec:

```powershell
az containerapp exec --subscription '<subscription-id>' --resource-group '<dedicated-group>' `
  --name '<gateway-name>-console' --command 'python3 /app/console/operate.py accept'
```

It verifies an anonymous redirect and a wrong-principal 403, then obtains the exact operator MI token in memory and drives the real public HTTPS origin. It sends bounded baseline, failover and minute-governance traffic, then resets. Only credential-free results are saved to `/tmp/console-acceptance.json`; preserve them before restarting the app. Do not run acceptance while someone is operating a scenario.

Inference tokens remain server-side. The existing A/B managed identities perform inference; a separate managed operator identity has demo-group read access, Log Analytics read access and only workspace/alias/model configuration writes scoped to this gateway. It cannot grant permissions or call models as an operator. ACR pull is scoped to the dedicated registry. Images are built with `az acr build` and deployed by immutable digest; the base images are also digest pinned.

Baseline, 80/20, failover/recovery, minute token allowance, hourly allowance and reset controls invoke fixed scripts with bounded synthetic prompts. There is no arbitrary prompt/command endpoint. The cost button remains disabled while native pricing is incomplete. GET is read-only; POST requires same-origin and a per-process CSRF token. A single replica and process-wide lock serialize the complete scenario and native verification. Redeployment first places the old console in maintenance and refuses any running scenario. Do not operate CLI/portal mutations concurrently.

HTTP status, observed token usage, latency and trace IDs arrive first. Backend selection, policy error origin and estimated cost appear **only after joining actual native telemetry**, sometimes several minutes later. `verified` requires the existing strict native verifier to pass. Missing telemetry is unknown, not zero or success. Runs restore baseline in `finally`; startup repairs only recognized demo faults. Failed restoration disables controls and requires an explicit operator reset/redeployment. Histories are bounded to 20 runs and are ephemeral across app restarts; preserve acceptance evidence outside the container.

The 80/20 scenario emits 50 requests and takes approximately six minutes at the qualified backend rate. Failover emits seven, baseline four, and allowance checks never exceed 12. There are no client retries. Failover deliberately includes an all-backends-down error before recovery; a visible 503 in that phase is expected. Governance rejection must be native `tokenLimit`, with B continuing successfully. All observations still require native verification, including requests already accepted across a counter boundary.

### Application Insights linkage

The existing workspace-based component is enabled for native OTLP using the actual portal contract, `Microsoft.Insights/components@2020-02-02-preview` and `AzureMonitorWorkspaceIngestionMode: Enabled`. Azure creates its managed DCR/DCE/Monitor workspace and publishes `DataCollectionRuleResourceId` and the three `OTLP*Endpoint` properties. The gateway still uses its native `OpenTelemetry` exporter, managed identity, `https://monitor.azure.com/` audience and no prompt/response payload capture. Workbook queries continue against the same Log Analytics workspace, using the actual Insights component scope and native server hostname because this managed DCR does not enrich `cloud.resource_id`.

The portal distinguishes an Insights integration from a custom exporter by resolving the endpoint's immutable DCR ID and finding the component whose `DataCollectionRuleResourceId` points back to it. Merely enriching a manual DCR with an Insights reference is insufficient.

Live acceptance on the dedicated deployment found exactly one matching component through the portal-equivalent Resource Graph query and verified four fresh A/B baseline requests: both backends, HTTP 200, 17 tokens each, estimated USD 0.000066 each. The native verifier passed. This is data/control-plane evidence; the minimized portal browser did not permit a verified visual observation of the banner.

**Required IaC exception:** Azure's managed monitoring group denies `Microsoft.Resources/deployments/write` but explicitly permits direct role-assignment writes. Therefore its Monitoring Metrics Publisher grant cannot be deployed through a nested Bicep module in that group. `deploy.ps1` verifies the component/DCR cross-reference and subscription, then idempotently reads/creates/verifies the exact-DCR role using ARM `2022-04-01`. It neither modifies the deny assignment nor grants a broader role. All other monitoring resources remain in Bicep. The previous manual OTLP resources are retained to avoid destructive migration; only the Insights-linked exporter receives new traffic.

Deleting the dedicated demo group also deletes its Insights component. Its additional provider-managed monitoring group is outside the cleanup allowlist; do not force-delete it or remove its deny assignment. Check the provider-managed lifecycle after component deletion and investigate any retained resources through the supported Azure resource lifecycle.

Use PowerShell 7.4+, Azure CLI and an existing Bicep installation. The deployment operator needs resource creation permissions and role-assignment write permissions. A reader alone cannot deploy. Telemetry inspection also requires Log Analytics query access and Monitoring Data Reader on the Azure Monitor workspace; these are separate from gateway inference roles.

Copy `config\demo.example.json` to `config\demo.local.json`. Fill every placeholder with an authorized, explicit choice:

- Subscription ID, a new dedicated `rg-aigw-demo-*` group and globally unique gateway name.
- Gateway region/SKU, model name/version/deployment/SKU/capacity and monitoring region.
- Two distinct **service-principal object IDs**, not client/application IDs or personal user identities.
- Verified maximum input/output USD per million tokens across both backends, source/date, and a conservative per-run estimate ceiling.

The zero example prices intentionally block traffic. The model must support nonstreaming OpenAI v1 Chat Completions and `max_completion_tokens`. Both deployments use the same selected model/version. Defaults in the older backend module are not availability assertions; the gateway entrypoint supplies explicit model settings.

Alternatively, set `"provisionDemoCallers": true` and remove `teamAObjectId`/`teamBObjectId` from the local configuration. Bicep then creates two dedicated user-assigned managed identities in the demo group; their resolved object IDs come from verified deployment outputs. Combining this opt-in with external caller IDs is refused.

```powershell
Copy-Item .\config\demo.example.json .\config\demo.local.json
# Edit the ignored local file before continuing.
.\scripts\preflight.ps1 -ConfigPath .\config\demo.local.json -Offline
.\tests\local.tests.ps1
```

Do not run live commands until the subscription is authorized. The scripts do not run `az account set` or create directory applications. Do not reuse another person's environment. Ownership tags include this gateway's name; existing groups without matching markers are refused.

Use the same region twice unless **both** regional availability and quota have been verified. Two endpoints in one region demonstrate endpoint resilience, not regional disaster recovery. `GlobalStandard` can process outside the resource region.

## 2. Discover, validate and deploy

```powershell
# Read-only subscription/provider/model/SKU/quota discovery:
.\scripts\preflight.ps1 -ConfigPath .\config\demo.local.json
# Mandatory ARM validate and what-if, no resource creation:
.\scripts\deploy.ps1 -ConfigPath .\config\demo.local.json
# Review the changes, then explicitly provision:
.\scripts\deploy.ps1 -ConfigPath .\config\demo.local.json -Apply
```

Preflight refuses missing provider registration, unsupported advertised API/region/model/SKU and insufficient or unresolvable quota. It does not reserve capacity. ARM validation is still required to check gateway SKU acceptance, monitoring-region availability, account eligibility and template expressions.

Bicep creates the group, two Foundry accounts/projects/model deployments, system-assigned gateway identity, providers/models/aliases, RBAC, Log Analytics, Azure Monitor workspace, Application Insights, DCE/DCR, OTLP exporter and Workbook. An optional monthly resource-group Cost Management budget is enabled only with `budgetEmails`; it is an asynchronous alert, not an enforcement mechanism.

The gateway receives Cognitive Services OpenAI User on the two backend accounts. A/B receive AI Gateway Models User on the **two aliases only**, not on the raw registered models or Foundry accounts. Test with otherwise unprivileged workloads: inherited grants can permit bypass outside this demo's boundary.

Configuration profiles use the stable `2026-11-01` API. Workspace policy changes use PATCH because the default workspace is service-created. The two demo-owned aliases use replacement PUT so resetting can remove the optional attempt budget: the live service rejects even an explicit zero budget without failure actions. Every write reads the HTTP ETag, supplies `If-Match`, and waits for matching read-back. Concurrent edits or missing ETags cause failure, not wildcard overwrites. Read-back is control-plane evidence, not proof of data-plane convergence.

The qualified service omits submitted policy IDs from GET responses. Ownership is therefore checked against the exact versioned policy configuration, not an absent ID marker; unknown allowances are refused. The ownership check and PATCH use the same ETag snapshot.

## 3. Authenticate two workloads

Provide two short-lived Entra tokens in the runner process environment, `DEMO_TEAM_A_TOKEN` and `DEMO_TEAM_B_TOKEN`. Acquire them using each existing workload's approved authentication mechanism. For a CLI already authenticated **as the intended workload**, capture rather than print the token:

```powershell
# Run in an authorized workload context; do not switch a shared CLI context.
$token = az account get-access-token --subscription '<explicit-subscription-id>' `
    --resource 'https://ai.gateway.azure.com' --query accessToken --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Workload token acquisition failed.' }
# Set DEMO_TEAM_A_TOKEN or DEMO_TEAM_B_TOKEN in the runner process via your approved secret channel.
# Never persist $token in JSON, transcripts, screenshots, command arguments or Git.
```

Application/managed-identity scope: `https://ai.gateway.azure.com/.default`. Delegated scope: `https://ai.gateway.azure.com/Data.All` (not used by this workload demo). No subscription key is necessary. The module checks `oid`, audience and expiry locally to catch mix-ups; this is **not signature verification**. The gateway must validate the token and RBAC. Refresh tokens before long runs; a token valid for two minutes is not guaranteed to cover every bounded run.

### Optional Azure-hosted managed callers

For provisioned demo identities, a small ACI runner can acquire A/B tokens without secrets or local account switching:

```powershell
.\scripts\deploy-runner.ps1 -ConfigPath .\config\demo.local.json
.\scripts\deploy-runner.ps1 -ConfigPath .\config\demo.local.json -Apply
.\scripts\run-with-managed-callers.ps1 -ConfigPath .\config\demo.local.json -Scenario baseline
# Correct-audience direct Foundry access must be denied for both callers:
.\scripts\run-with-managed-callers.ps1 -ConfigPath .\config\demo.local.json -Scenario access-isolation
```

The digest-pinned Microsoft Azure CLI container has no public ingress. Its two identities have only the same alias permissions as external callers. The wrapper uses authenticated ARM exec and ACI's documented IMDS endpoint, checks credential resource/lifetime metadata and any returned client ID, keeps credentials in process memory, restores existing environment values afterward, and invokes the bounded PowerShell scenario runner locally. It is not a request proxy, retry engine or native gateway feature.

The access-isolation check requests Cognitive Services tokens explicitly for each identity, rather than reusing wrong-audience gateway tokens. It requires the native `PermissionDenied` code, not just any 401/403, from both Foundry deployments. Foundry access tokens are treated as opaque; they need not have a client-readable JWT payload. Four such HTTP 401 denials were observed on the qualified target. This does not independently qualify a direct registered-model runtime route: an experimental provider-qualified model name returned 404 and was not counted as RBAC proof.

Compute automatically exits after four hours. Stop it explicitly when checks are complete (substitute the actual explicit subscription/group/name):

```powershell
az container stop --subscription '<subscription-id>' --resource-group '<demo-group>' --name '<gateway-name>-runner'
```

Restart with `az container start` for another session if needed. The optional runner and provisioned demo identities are included in dedicated-group cleanup; external directory identities are never deleted.

## 4. Run and verify

```powershell
.\scripts\run-scenario.ps1 -ConfigPath .\config\demo.local.json -Scenario baseline
# Copy the actual result path printed by the runner, not this placeholder.
.\scripts\verify-results.ps1 -ConfigPath .\config\demo.local.json -ResultsPath '.\.demo\<run-id>.json'
```

Baseline sends four real requests: A/B through `demo-chat` (backend 1) and `demo-alt` (backend 2). The gateway hostname and common advertised Chat Completions path are read from ARM, not guessed. Completion bodies are discarded; HTTP status, token usage, error code, timing and trace ID are saved locally.

The terminal shows immediate HTTP observations. **Only successful native verification produces `<run-id>.verified.json`.** Verification joins OTelSpans/OTelLogs by the client W3C trace ID, checks authenticated identities/status and serving backend, and rejects incomplete or ambiguous evidence. Allow ingestion delay, then rerun the verifier without generating more traffic. Queries cover the last hour. Missing traces or attributes are inconclusive, never success.

Run one scenario at a time; the workspace configuration is shared. Each run restores baseline configuration in `finally`. A failed restoration remains an explicit error and is recorded in the run file.

| Scenario | Command suffix | Required native evidence |
|---|---|---|
| Stable aliases | `-Scenario baseline` | Both real backends serve the intended aliases for A/B. |
| Weighted routing | `-Scenario weighted-routing -Samples 100` | 50-200 successful requests; backend 1 fraction within four binomial standard deviations of 0.8. Not an exact 80/20 promise. |
| Failover/recovery | `-Scenario failover` | Healthy primary/secondary, two backend sends on failover, one send while excluded, visible all-down error, restored primary and secondary. |
| Token rate | `-Scenario token-rate` | A rejected repeatedly through both aliases while B continues; rejection attributed to `tokenLimit`. |
| Cumulative tokens | `-Scenario token-quota` | Same checks with an hourly token allowance. It is not a lifetime token quota. |
| Estimated spend | `-Scenario cost-limit -BaselineEvidencePath '.\.demo\<baseline-id>.verified.json'` | Fresh priced baseline on both backends; native metrics explicitly `price_missing=false`; A cost rejection attributed to `costLimit` while B continues. |

Use the same `run-scenario.ps1` prefix with `-ConfigPath` for each suffix, then verify its actual saved result path. Token scenarios add synthetic input markers to A's request only: 640 for the minute test and 160 for the hourly test, within the qualified model's 1,024-token input estimate. B keeps the short control prompt. Request ceilings never increase automatically. The larger minute input leaves time to demonstrate B continuing between A rejections under conservative backend pacing; the shorter input recovered before the alternate-alias probe and was not certified.

Governance is per authenticated identity at **workspace** scope, shared across both aliases/backends. It is not a pooled team allowance. The cost profile renders an `oid` override for A (USD 0.0001/hour) with a larger independent B/default allowance (USD 0.1/hour). These are estimates, not exact billing.

An exhausted identity can remain exhausted after reconfiguration. Start with fresh authorized workloads or wait for the applicable renewal. The minute test aligns its start to a UTC minute to reduce timing variation, but this is not proof of calendar-window enforcement: the service admitted a later request within that same minute in an earlier short-load test. Rejection continuity can therefore become inconclusive before a wall-clock boundary. The runner does not fake a reset or characterize an unmeasured refill algorithm.

Token allowances are not strict hard ceilings. The verified hourly run accepted three 184-token A completions (552 tokens) before rejecting further A calls with the configured 256-token allowance, even with one request in flight. The verified minute run accepted one 664-token A completion, then returned native `tokenLimit` HTTP 429 on both aliases while B continued. Native accounting/admission timing can overshoot; do not promise that accepted usage stays below the configured count.

### Cost safety

Cost-limit refuses traffic without a native-verified baseline from the same gateway with nonzero per-response costs on both serving backends in the last ten minutes. It also queries unaggregated native cost metric series for both aliases with complete pricing flags; missing/zero/incomplete metrics stop the scenario. It does not infer price completeness from positive costs alone.

The runner limits calls (at most 12 governance, 8 failover, 200 weighted), completion tokens (64), one request in flight and **zero client retries**. It reads the actual deployment request/token limits and enforces monotonic minimum start-to-start spacing for the maximum input and attempt bounds, rather than adding a full delay after a slow response. The qualified capacity-10 backends allow only 10 requests/minute each; an unpaced routing test hit a real upstream 429 and was not certified. A 100-call run can therefore take more than ten minutes. Its conservative model-token estimate includes 1,024 input tokens per backend attempt and both possible failover sends, using the supplied maximum prices. It excludes gateway/monitoring/fixed charges and is not a financial guarantee.

Native cost policies check recorded spend before admission and charge after completion; in-flight work can overshoot. Missing native prices can fail open. UTC calendar boundaries renew cost allowances. Never describe this as an exact invoice or strict hard budget.

### Fault demonstration

The failover runner temporarily maps a registered model to `/demo-injected-unavailable`, expecting an upstream 404. The special 404 rule is **laboratory configuration only**. Native failure rules also cover null responses and 408/429/500/502/503/504, but real network timeouts, regional outages and throttling have not been tested.

No injector service is deployed. The runner performs no client retry or backend selection. It restores the exact original explicit endpoint mappings, waits 35 seconds for the configured 30-second exclusion, then requests recovery. Propagation may take longer; a failed check must remain visible rather than being presented as success.

## 5. Show the Workbook

Open the deployed Log Analytics resource's Workbook named **AI Gateway - teams A/B**. Its three views show native request health/latency (p50/p95), backend/token/estimated-cost usage with missing-record counts, and trace-level correlation.

The KQL is versioned in `observability\requests.kql`. It uses real OTelSpans/OTelLogs fields, not classic APIM tables. The deployed service emits workspace-relative backend names (`backend-1/demo-model`, `backend-2/demo-model`) and preserves incoming W3C trace IDs. Scripted queries use JSON-file REST transport to preserve multiline KQL on Windows. An absent policy error span means rejection attribution remains unknown. Do not replace missing native evidence with client-side labels.

Telemetry is delayed and may be capped/dropped: the Log Analytics daily cap is 1 GB and retention 30 days. No remaining quota is invented. Payload capture is disabled. A/B labels correspond to workload object IDs, not customer data.

## 6. Reset and cleanup

```powershell
# Repair recognized lab endpoint faults and restore baseline routing/policies:
.\scripts\reset-demo.ps1 -ConfigPath .\config\demo.local.json
# Preview exact dedicated-group cleanup:
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json -WhatIf
# Confirm the built-in high-impact prompt, or use -Confirm:$false deliberately:
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json
Remove-Item Env:\DEMO_TEAM_A_TOKEN, Env:\DEMO_TEAM_B_TOKEN -ErrorAction SilentlyContinue
```

Reset does not erase counters, cancel in-flight calls or immediately expire native exclusions. Wait for renewal/exclusion before repeating. Interrupted processes may not execute `finally`; reset repairs only recognized demo mappings and refuses unknown configurations.

Cleanup checks subscription deployment outputs, group ownership markers and an exact resource allowlist. Application Insights can automatically create a Failure Anomalies alert; cleanup accepts only its exact expected name, detector and exclusive link to this demo's component. It refuses groups with foreign resources or alerts targeting other components, then waits for group deletion. Inspect unexpected resources manually; never broaden deletion to a subscription or shared group. External directory identities are not deleted. Subscription deployment history and provider-managed soft-delete retention can remain after resource-group deletion.

After workshop cleanup, inspect the registration named `<gateway-name>-console` using `consoleAuthApplicationObjectId` in the ignored local configuration. Verify its object ID, `appId` against `consoleAuthClientId`, display name and ownership, then remove that exact application with `az ad app delete --id '<verified-application-object-id>'`. This also retires its browser-login credentials; do not delete any other application by name alone. Rotated credentials expire after 30 days; remove superseded `console-easy-auth` credentials only after confirming the deployed login and recorded current key ID.

## Remaining live acceptance

Preflight, ARM validation/what-if, infrastructure deployment and a final deployment replay succeeded. A fresh post-replay baseline was natively verified with the same hostname; baseline reapplications preserved the workspace and both alias ETags. Weighted/failover/minute/hourly acceptance, direct Foundry permission-denial checks, all three deployed Workbook queries and cleanup preview also succeeded. The optional ACI runner was explicitly stopped and its `Stopped` state read back; the gateway, backends and monitoring remain deployed.

What-if could not analyze some dynamically resolved role-assignment IDs; the actual replay succeeded. Resource-group deletion was not performed merely to demonstrate cleanup. Two-region resilience, real network timeouts and the raw registered-model authorization route remain unqualified. There are no presentation screenshots or fallback captures.

The actual native aggregate cost series reports `azure.ai_gateway.price_missing="true"` despite nonzero response-cost estimates. The cost guard deliberately refuses enforcement traffic under this condition; positive costs alone do not prove complete pricing. Do not remove the guard or present estimated costs as a certified hard cap.
