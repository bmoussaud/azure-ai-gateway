# Contract qualification and limitations

Public documentation is qualification evidence, **not deployment evidence**. The implementation uses the new `Microsoft.ApiManagement/aigateways` product. There is no `Microsoft.ApiManagement/service` instance, classic XML policy or automatic model selection.

## Sources

- [Product overview](https://learn.microsoft.com/en-us/azure/ai-gateway/overview), [concepts](https://learn.microsoft.com/en-us/azure/ai-gateway/concepts), [migration boundary](https://learn.microsoft.com/en-us/azure/ai-gateway/migrate-api-management).
- [Official operational documentation](https://ai.gateway.azure.com/docs): models/API formats, priorities and weights, failover, security/Entra, governance/token-rate-limit, cost-limit and observability/telemetry-reference. This site is a SPA; its publicly served markdown was inspected, not inferred from classic APIM.
- [Pinned stable resource-manager OpenAPI](https://github.com/Azure/azure-rest-api-specs/blob/965a33b4c632fb1aaf5f2ea02e6d603e1c81baa6/specification/apimanagement/resource-manager/Microsoft.ApiManagement/AIGateway/stable/2026-11-01/openapi.json), API `2026-11-01`. The public TypeSpec in the same directory hierarchy supplies the same resource contracts.
- [Foundry routing concepts](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/model-router-ai-gateway). Its automatic-selection preview is outside this demo.
- [Azure Monitor OTLP orchestration](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/opentelemetry-protocol-ingestion), [Microsoft's manual DCE/DCR template](https://github.com/microsoft/AzureMonitorCommunity/blob/master/Azure%20Services/Azure%20Monitor/OpenTelemetry/OTLP_DCE_DCR_ARM_Template.txt).
- [OTelSpans table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/otelspans), [OTelLogs table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/otellogs), [Azure Monitor PromQL API](https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-api-promql).
- [Pinned Cognitive Services catalog schema](https://github.com/Azure/azure-rest-api-specs/blob/965a33b4c632fb1aaf5f2ea02e6d603e1c81baa6/specification/cognitiveservices/resource-manager/Microsoft.CognitiveServices/CognitiveServices/stable/2025-06-01/cognitiveservices.json).

Do not substitute preview sample payloads: stable providers use `modelProviderType` with endpoint objects, models use `deployment`, and exporters use `telemetryExporterType` with separate authentication. The Bicep compiler's missing gateway type bundle is suppressed locally with `BCP081`; successful compilation cannot validate the remote schema. ARM validation and live acceptance are mandatory.

## Capability matrix

| Area | Qualified public contract / implementation | Remaining qualification |
|---|---|---|
| Resource | System-assigned `aigateways`, **Standard** SKU, service-assigned frontend hostname. Live ARM creation rejected Consumption with `InvalidSkuName`: "The supported AI Gateway SKU name is 'Standard'." Generic CLI SKU options are not a native-product guarantee. | Subscription entitlement, regional availability and billing. |
| Regions | Gateway docs advertise australiaeast, canadaeast, centralus, eastus, eastus2, francecentral, japaneast, northcentralus, northeurope, southcentralus, southeastasia, swedencentral, uksouth, westeurope, westus, westus2. | Provider metadata in the chosen subscription takes precedence. OTLP/model region support is separate. |
| Backend | Two real AIServices accounts, each with a project and parameterized OpenAI deployment. Managed identity; local account keys disabled. | Model/version/SKU/capacity and v1 Chat Completions compatibility. GlobalStandard is not regional residency. |
| Providers/models | Foundry endpoint object, `resourceIds`, managed-identity audience; deployment ARM ID/provider model name/version; explicit API-to-path mapping. | Actual path behavior, Entra backend authorization and control/data-plane convergence. |
| Runtime | Service-created `default` workspace, advertised common `/chat/completions` path, alias callable name in `model`. | Entra authorization and inference on both real backends. |
| A/B identities | Entra `oid`/audience guard; Models User role for A/B on each of seven fixed aliases; separate gateway-to-Foundry grants. | Inherited grants can bypass intended boundaries. |
| Fixed scenario aliases | Bicep loads versioned JSON definitions. Runtime only selects `model`; full `demo-chat` envelope and ETag compared before/after. Console operator configuration role is read-only. | Public sources inspected do not publish a numeric alias-count cap. Seven aliases must be accepted/read back on the actual target; no unlimited-capacity claim. |
| Names and target count | ARM alias name: `^[a-zA-Z0-9_.-]+$`; registered model: `^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`; provider: `^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`. Chosen names are lowercase and client alias names match their ARM names. Maximum 30 targets per alias. | Client-facing `aliasName` is distinct from the ARM resource name; do not infer client-name constraints from its ARM regex. |
| Weighted routing | Fixed `scenario-weighted-80-20`: equal priority, weights 80/20, ten calls, ≤2 s intentional pacing. | Actual distribution, not exact 8/2 or a statistical qualification. Historical 50-call qualification remains historical. |
| Routage conditionnel par identité (conditions CEL de backend) | Fixed `scenario-identity`, `backendModels[].when = "@cel(...)"`, validated `authorization.identity.id` (`tenantId:objectId`), not a caller header. Conditions precede priority, weight, affinity and subsequent selections. Ten alternating A/B calls assert native `oid`/backend. | Hard pin: B cannot fail over to Backend 1. Compatible API endpoints required; at most 30 backends per alias. Conditions are alias-local eligibility, not permission grants or alias RBAC. The four-call backend-2-down result below is historical; runtime endpoint mutation is now refused. |
| Failover | Fixed dedicated permanent-fault provider/model, then Backend 2; one additional backend attempt, no client/same-backend retry and no persistent exclusion. Rules for null/408/429/5xx and lab-only 404. | Each completion must prove two native backend sends. Current scenario does not test all-down, recovery, real network timeout or regional outage. |
| Token rate | `scenario-token-rate`: fixed `tokenLimit`, 256, minute, resource-scope identity counter. | Actual native rejection attribution and renewal timing. |
| Token quota | `scenario-token-quota`: independent 256/hour resource-scope identity counter. | Not a global cross-alias envelope, lifetime quota or reset API. |
| Cost limit | `costLimit`, USD amount, hour/day/week/month/year; authenticated claim overrides; workspace identity counter. Runner requires native pricing evidence. | Actual catalog pricing and rejection attribution. Missing price fails open; in-flight overshoot possible. |
| Cost alert | Optional monthly resource-group Cost Management budget/80% alert. | Offer/permission eligibility and asynchronous notification delivery; not enforcement. |
| Native telemetry | OTLP MI exporter, payload off, explicit `tid`/`oid`, Azure Monitor DCE/DCR and native OTLP tables. | Actual ingestion, latency, resource attributes, span propagation and label availability. |
| Workbook | Native request health, attributed/unattributed errors, latency, serving backend, tokens, estimated USD, correlation and missing fields. | Query behavior on actual emitted records; no invented remaining allowance. |
| IaC/config | Bicep resources, shared versioned JSON definitions, runtime read-back only, dedicated ownership guards and exact cleanup allowlist. Aliases omit the attempt budget when there are no failure actions, including zero. | ARM validate/what-if plus real deployment are required: provider validation occurs after ARM validation. |

## Counter boundary

`counterKey: ["identity"]` and `scope: "resource"` are intentional for fixed demonstrations. Each scenario alias has a separate A/B allowance. Switching aliases intentionally changes strategy and allowance: this is **not** a global anti-bypass envelope. The default workspace has no inherited policy. Counter identities are validated Entra identities, not arbitrary team headers. A/B are two synthetic workloads, not a group-based team budget. Start, Stop and verification never reset counters; natural renewal and previously admitted usage remain observable.

Identity overrides require exactly one selector, claims or API-key resource ID, and match authenticated claim values. The disabled cost profile retains A's `oid` placeholder as contract documentation only; it is not deployed or executed. No gateway API keys are provisioned.

The intended security boundary excludes additional gateways, direct Foundry access and inherited administrative roles. Subscription administrators can change configuration. This demo cannot prevent a separately authorized route, including another intentionally independent scenario alias.

## Telemetry contract used

Caller instrumentation measures the PowerShell `HttpClient` inside the ACA,
not the optional ACI runner. Azure Monitor exports CLIENT spans under separate
Application A/B service roles, preserving the exact outgoing W3C IDs.
These arrive in `AppDependencies`; `observability/caller-map.kql` joins them
to native gateway `OTelSpans` by operation/trace ID and checks the parent span.
This does not fabricate an ACA server span or replace native backend proof.
Ingestion uses the ACA operator managed identity and Monitoring Metrics Publisher
scoped to Insights, with local authentication still disabled. The managed DCR
deny assignment is not bypassed. Application Map rendering is a separate,
eventually consistent observation from a successful export or KQL join.

The shared query uses `ResourceAttributes["cloud.resource_id"]` for the previous manual OTLP pipeline. The actual Insights-managed DCR does not enrich that attribute: new records instead carry the dedicated component `_ResourceId`, gateway `ScopeName`, and the server span's exact `server.address`. The query supports both verified shapes, filtering the Insights component and gateway hostname rather than dropping the isolation filter. `TraceId`, server span `DurationMs`, `StatusCode`, `http.response.status_code` and exported `azure.ai_gateway.identity.claims.oid` remain unchanged. Logs supply `gen_ai.request.model`, `azure.ai_gateway.client.usage.total_tokens` and `azure.ai_gateway.client.token.cost`; routing spans supply `azure.ai_gateway.routing.backend` and `.attempt`.

Error attribution requires an error policy span carrying `azure.ai_gateway.policy.type`. If that detail is not emitted, the verifier refuses to certify token/cost rejection origin from HTTP status alone. The live service emits workspace-relative serving backend names (`backend-1/demo-model`, `backend-2/demo-model`), which the assertions match within the selected gateway's native records.

Native cost metric `azure.ai_gateway.client.token.cost` carries `azure.ai_gateway.price_missing`. The pricing guard queries dotted OpenTelemetry metric/label names through PromQL, selects no `gen_ai.token.type` breakdown and requires explicit `"false"` on every returned aggregate series. Absence of the flag is unknown. The two aliases' fresh native baseline traces prove their different backends; a summed positive cost alone cannot prove both prices.

## Local versus Azure evidence

The fixed-alias migration supersedes the dynamic-profile workflow described in
the historical results below. Its evidence must independently show six active
scenario aliases, alias-local policy attribution, immutable `demo-chat` snapshots,
and zero runtime configuration writes. The Chromium DOM regression uses synthetic
API responses and checks a real Start click clears old routes, native proof paths,
meters, lock, backend states and table rows before a new job appears. It then
checks the new alias is drawn without inherited proof. This is DOM behavior
evidence, not Azure telemetry or a live visual portal observation.

Actual protected HTTPS fixed-alias qualification observed baseline A/B 2/2 on
Backend 1; weighted 8/10 on Backend 1 and 2/10 on Backend 2; four permanent-fault
404-to-200 native failovers; minute A 429 and hourly A 403 `tokenLimit` rejections
with two B completions each; identity A 5/5 on Backend 1 and B 5/5 on Backend 2.
All have zero client retry. Raw failover spans independently show the isolated
`backend-fault/demo-unavailable` attempt, not a fault on a real model.
Evidence: `.demo\fixed-initial-jobs.json`, `.demo\fixed-failover-attempts.json`,
`.demo\fixed-identity-verified.json`. The identity job initially refused
certification because two alias logs lagged the request spans; strict read-only
reverification of those same requests succeeded. The console now waits for
complete native joins rather than assuming span count implies log completeness.
Full ARM envelopes and ETags for all seven aliases were identical before and
after this campaign, including `demo-chat`. The optional ACI runner remained
Stopped. This control-plane comparison does not imply counters were reset.
The join-completeness fix is deployed in ready console revision `0000016`;
a new protected HTTPS identity campaign passed all ten native assertions
(A five Backend 1, B five Backend 2), authentication denials, CSRF and overlap.
`.demo\fixed-console-acceptance.json` explicitly aggregates the five earlier
scenario jobs and this final identity job. `.demo\fixed-configuration-unchanged.json`
records exact full-body/ETag comparison after the final run as well.

### Historical dynamic-profile qualification

`tests\local.tests.ps1` uses synthetic JSON/JWT/ARM fixtures and a loopback HTTP 503 server. It checks safety boundaries, identity mix-ups, fixed resource-scoped policies/read-only checks, cost completeness refusal, endpoint discovery, cleanup refusal and the client's nonstreaming/no-retry/sanitized result behavior. It makes no Azure calls.

On 2026-11-24, preflight, ARM validation/what-if and actual deployment succeeded in East US 2 with Standard and GPT-6 Sol `2026-09-22` GlobalStandard capacity 10 per backend. Four real baseline completions (A/B through both aliases) were verified against native trace IDs, identities, status and backends. Native records show 17 tokens and USD 0.000066 per baseline completion, with ingestion delayed by minutes.

The paced routing run completed 50 real calls: native backend spans show 40 primary and 10 secondary (80/20), not a client-generated distribution. Both identities also received native `PermissionDenied` responses (HTTP 401) from both Foundry deployments using the correct Cognitive Services audience. An unqualified direct registered-model name returning 404 was not counted as authorization proof. Cleanup preview succeeded without deleting the environment, including verification of the service-generated Failure Anomalies alert's exact component scope.

Native failover verification confirmed two backend sends on failover, one while the primary was excluded, visible all-down HTTP 503, and recovery of both backends. All three queries extracted from the deployed Workbook executed successfully against actual native records.

Identity routing was deployed and verified through the protected console's public HTTPS API: ten HTTP 200 calls, native A `oid` selecting `backend-1/demo-model` 5/5 and B `oid` selecting `backend-2/demo-model` 5/5, one backend send each, zero client retries and two-second pacing. A separate four-call negative run observed B healthy 200, B 404 on its pinned Backend 2 after lab fault injection, then two A 200 responses on Backend 1; B never selected Backend 1. Both runs restored and read back baseline; exact backend endpoint mappings were restored and the dedicated ACI runner stopped. Local evidence is `.demo\identity-console-acceptance.json` and `.demo\5a944b9d63a346c5acd1cd4d2d3698f2{,.verified}.json`. Native HTTPS denials (anonymous 401, wrong principal 403), CSRF 403 and overlap 409 passed. The new UI was not visually observed; no regional/network-failure qualification is implied. The condition only governs `demo-chat`; hidden, separately authorized `demo-alt` is unchanged. Models User RBAC grants alias access, not backend pinning.

The hourly token run verified native `tokenLimit` rejections (HTTP 403) for A on both aliases while B continued. Three accepted A completions consumed 552 tokens before further admission was refused against a configured 256-token allowance; this is not a strict hard token ceiling. The final minute run accepted 664 A tokens, then verified native HTTP 429 `tokenLimit` rejections on both aliases with B continuing between A rejections. Earlier short-input minute tests recovered before the alternate-alias check, including within the same UTC minute; no precise refill algorithm or cross-alias bypass is inferred from those incomplete runs.

The aggregate native cost metric currently marks pricing incomplete (`price_missing="true"`). A fresh, natively verified baseline followed by the real guard confirmed cost-enforcement traffic is refused, even though estimated costs are nonzero. The pinned native registered-model schema exposes no price override; the guard is not bypassed. An initial unpaced weighted test hit a genuine upstream 429; the runner now derives monotonic start-to-start spacing from actual ARM deployment limits rather than assuming throughput from SKU/capacity. Other scenario results must be qualified independently.

A final infrastructure replay passed preflight, ARM validation/what-if and deployment. Some dynamic role-assignment IDs were unanalysable by what-if, not silently reported as no-op. The actual replay retained the endpoint, then a fresh baseline passed native verification; its baseline configuration reapplications left all workspace/alias ETags unchanged. ACI compute was explicitly stopped and read back as `Stopped`; the demo foundation remains deployed. Deletion, regional disaster recovery and real network timeout behavior were not tested.
