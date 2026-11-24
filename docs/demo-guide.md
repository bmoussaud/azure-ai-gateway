# Operator guide

## Acceptance status

This repository contains a locally compiled/linted Bicep implementation and synthetic PowerShell tests. **It has not been deployed or exercised against Azure.** No model availability, gateway SKU acceptance, propagation time, trace shape or pricing has been observed in a target subscription. Do not present synthetic fixtures as gateway results.

Use the [capability matrix](capabilities.md) for the public contracts and remaining uncertainties. The deployment entrypoint is `infra\demo.bicep`, at subscription scope. `infra\main.bicep` is its Foundry backend module, not a standalone gateway deployment.

## 1. Select the dedicated target

Use PowerShell 7.4+, Azure CLI and an existing Bicep installation. The deployment operator needs resource creation permissions and role-assignment write permissions. A reader alone cannot deploy. Telemetry inspection also requires Log Analytics query access and Monitoring Data Reader on the Azure Monitor workspace; these are separate from gateway inference roles.

Copy `config\demo.example.json` to `config\demo.local.json`. Fill every placeholder with an authorized, explicit choice:

- Subscription ID, a new dedicated `rg-aigw-demo-*` group and globally unique gateway name.
- Gateway region/SKU, model name/version/deployment/SKU/capacity and monitoring region.
- Two distinct **service-principal object IDs**, not client/application IDs or personal user identities.
- Verified maximum input/output USD per million tokens across both backends, source/date, and a conservative per-run estimate ceiling.

The zero example prices intentionally block traffic. The model must support nonstreaming OpenAI v1 Chat Completions and `max_completion_tokens`. Both deployments use the same selected model/version. Defaults in the older backend module are not availability assertions; the gateway entrypoint supplies explicit model settings.

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

Configuration profiles use the stable `2026-11-01` API. Workspace policy changes use PATCH because the default workspace is service-created. Every PATCH reads the HTTP ETag, supplies `If-Match`, and waits for matching read-back. Concurrent edits or missing ETags cause failure, not wildcard overwrites. Read-back is control-plane evidence, not proof of data-plane convergence.

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

Use the same `run-scenario.ps1` prefix with `-ConfigPath` for each suffix, then verify its actual saved result path. The default 256-token limit is illustrative: actual tokenizer/output usage can prevent exhaustion within the six-call consumption bound. The runner stops **inconclusive** instead of increasing spend. Adjust the versioned demo limit deliberately after measuring baseline, not by blindly increasing traffic.

Governance is per authenticated identity at **workspace** scope, shared across both aliases/backends. It is not a pooled team allowance. The cost profile renders an `oid` override for A (USD 0.0001/hour) with a larger independent B/default allowance (USD 0.1/hour). These are estimates, not exact billing.

An exhausted identity can remain exhausted after reconfiguration. Start with fresh authorized workloads or wait for the applicable renewal. If a minute/hour boundary occurs during the test, rejection continuity may become inconclusive. The runner does not fake a reset.

### Cost safety

Cost-limit refuses traffic without a native-verified baseline from the same gateway with nonzero per-response costs on both serving backends in the last ten minutes. It also queries unaggregated native cost metric series for both aliases with complete pricing flags; missing/zero/incomplete metrics stop the scenario. It does not infer price completeness from positive costs alone.

The runner limits calls (at most 12 governance, 8 failover, 200 weighted), completion tokens (64), one request in flight and **zero client retries**. Its conservative model-token estimate includes 1,024 input tokens per backend attempt and both possible failover sends, using the supplied maximum prices. It excludes gateway/monitoring/fixed charges and is not a financial guarantee.

Native cost policies check recorded spend before admission and charge after completion; in-flight work can overshoot. Missing native prices can fail open. UTC calendar boundaries renew cost allowances. Never describe this as an exact invoice or strict hard budget.

### Fault demonstration

The failover runner temporarily maps a registered model to `/demo-injected-unavailable`, expecting an upstream 404. The special 404 rule is **laboratory configuration only**. Native failure rules also cover null responses and 408/429/500/502/503/504, but real network timeouts, regional outages and throttling have not been tested.

No injector service is deployed. The runner performs no client retry or backend selection. It restores the exact original explicit endpoint mappings, waits 35 seconds for the configured 30-second exclusion, then requests recovery. Propagation may take longer; a failed check must remain visible rather than being presented as success.

## 5. Show the Workbook

Open the deployed Log Analytics resource's Workbook named **AI Gateway - teams A/B**. Its three views show native request health/latency (p50/p95), backend/token/estimated-cost usage with missing-record counts, and trace-level correlation.

The KQL is versioned in `observability\requests.kql`. It uses real documented OTelSpans/OTelLogs fields, not classic APIM tables. The concrete emitted backend identifiers, error-policy span availability and W3C propagation must be verified in the target. An absent policy error span means rejection attribution remains unknown. Do not replace missing native evidence with client-side labels.

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

Cleanup checks subscription deployment outputs, group ownership markers and an exact resource allowlist. It refuses groups with foreign resources, then waits for group deletion. Inspect unexpected resources manually; never broaden deletion to a subscription or shared group. Directory identities are external and are not deleted. Subscription deployment history and provider-managed soft-delete retention can remain after resource-group deletion.

## Remaining live acceptance

Before calling this demo ready: authorize the subscription; pass preflight/ARM validate/what-if; deploy twice and prove idempotence; test both real workloads and denial of direct-model access; run/verify every scenario; inspect metric pricing flags and ingestion delays; exercise all-down and recovery; verify bounded spend and cleanup. Two-region resilience is a separate acceptance exercise. There are no live screenshots, fallback captures or successful Azure runs included.
