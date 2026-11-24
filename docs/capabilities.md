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
| Resource | System-assigned `aigateways`, SKU selectors Standard/Premium/Consumption, service-assigned frontend hostname. | Subscription entitlement, selected SKU, regional availability and billing. |
| Regions | Gateway docs advertise australiaeast, canadaeast, centralus, eastus, eastus2, francecentral, japaneast, northcentralus, northeurope, southcentralus, southeastasia, swedencentral, uksouth, westeurope, westus, westus2. | Provider metadata in the chosen subscription takes precedence. OTLP/model region support is separate. |
| Backend | Two real AIServices accounts, each with a project and parameterized OpenAI deployment. Managed identity; local account keys disabled. | Model/version/SKU/capacity and v1 Chat Completions compatibility. GlobalStandard is not regional residency. |
| Providers/models | Foundry endpoint object, `resourceIds`, managed-identity audience; deployment ARM ID/provider model name/version; explicit API-to-path mapping. | Actual path behavior, Entra backend authorization and control/data-plane convergence. |
| Runtime | Service-created `default` workspace, advertised common `/chat/completions` path, alias callable name in `model`. | Entra authorization and inference on both real backends. |
| A/B identities | Entra `oid`/audience guard; Models User role on two aliases; separate gateway-to-Foundry role grants. | Signed-token runtime behavior, inherited grants, direct backend/model access denied for otherwise unprivileged callers. |
| Weighted routing | Equal priority and weights 80/20. Statistical assertion with bounded 50-200 calls. | Actual distribution; not a deterministic ratio. |
| Failover | Priority order; one additional backend attempt; no same-backend retries; 30-second exclusion. Rules for null/408/429/5xx and a separate lab-only 404 rule. | Real error handling/timeouts, all-down, propagation, exclusion and recovery. No regional outage claim. |
| Token rate | `tokenLimit`, `count`, period minute, identity counter at workspace scope. | Real usage accounting/rejection timing and native policy attribution. |
| Token quota | Same public policy with hour period (day also supported); shared across aliases/models in the workspace. | Real cumulative exhaustion and renewal. No lifetime quota or fake reset API. |
| Cost limit | `costLimit`, USD amount, hour/day/week/month/year; authenticated claim overrides; workspace identity counter. Runner requires native pricing evidence. | Actual catalog pricing and rejection attribution. Missing price fails open; in-flight overshoot possible. |
| Cost alert | Optional monthly resource-group Cost Management budget/80% alert. | Offer/permission eligibility and asynchronous notification delivery; not enforcement. |
| Native telemetry | OTLP MI exporter, payload off, explicit `tid`/`oid`, Azure Monitor DCE/DCR and native OTLP tables. | Actual ingestion, latency, resource attributes, span propagation and label availability. |
| Workbook | Native request health, attributed/unattributed errors, latency, serving backend, tokens, estimated USD, correlation and missing fields. | Query behavior on actual emitted records; no invented remaining allowance. |
| IaC/config | Bicep resources, versioned JSON profiles, ETag PATCH/read-back, dedicated ownership guards and exact cleanup allowlist. | ARM validate/what-if, live replay idempotence and cleanup. |

## Counter boundary

`counterKey: ["identity"]` and `scope: "workspace"` are intentional. Resource-scoped counters would give each alias/model a separate allowance; a caller could then change aliases. Workspace scope is shared across compatible resources. Counter identities are validated Entra identities, not arbitrary team headers. A/B are two synthetic workloads, not a group-based team budget.

Identity overrides require exactly one selector, claims or API-key resource ID, and match authenticated claim values. This demo renders only A's configured `oid` into the versioned cost profile; it does not provision gateway API keys.

The intended security boundary excludes additional gateways, direct Foundry access and inherited administrative roles. Subscription administrators can change configuration. This demo cannot prevent a separately authorized route outside its workspace.

## Telemetry contract used

The shared query uses `ResourceAttributes["cloud.resource_id"]`, `TraceId`, server span `DurationMs`, `StatusCode`, `http.response.status_code` and exported `azure.ai_gateway.identity.claims.oid`. Logs supply `gen_ai.request.model`, `azure.ai_gateway.client.usage.total_tokens` and `azure.ai_gateway.client.token.cost`; routing spans supply `azure.ai_gateway.routing.backend` and `.attempt`.

Error attribution requires an error policy span carrying `azure.ai_gateway.policy.type`. If that detail is not emitted, the verifier refuses to certify token/cost rejection origin from HTTP status alone. The emitted serving-backend representation must match the model ARM IDs used in the assertions; inspect actual records before adapting any mapping.

Native cost metric `azure.ai_gateway.client.token.cost` carries `azure.ai_gateway.price_missing`. The pricing guard queries dotted OpenTelemetry metric/label names through PromQL, selects no `gen_ai.token.type` breakdown and requires explicit `"false"` on every returned aggregate series. Absence of the flag is unknown. The two aliases' fresh native baseline traces prove their different backends; a summed positive cost alone cannot prove both prices.

## Local versus Azure evidence

`tests\local.tests.ps1` uses synthetic JSON/JWT/ARM fixtures and a loopback HTTP 503 server. It checks safety boundaries, identity mix-ups, idempotent ETag updates, workspace counter scope, cost completeness refusal, endpoint discovery, cleanup refusal and the client's nonstreaming/no-retry/sanitized result behavior. It makes no Azure calls.

No Azure deployment, inference, telemetry, what-if, ARM validation or cost enforcement result is claimed. No subscription was selected. Use the operator guide's live acceptance checklist before a presentation.
