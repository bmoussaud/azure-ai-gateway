param location string
param prefix string
param gatewayName string
param gatewayHostname string
param gatewayPrincipalId string
param tags object

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}

resource metrics 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: '${prefix}-metrics'
  location: location
  tags: tags
  properties: {}
}

resource insights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: '${prefix}-insights'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
    DisableLocalAuth: true
    #disable-next-line BCP037
    AzureMonitorWorkspaceIngestionMode: 'Enabled'
  }
}

resource endpoint 'Microsoft.Insights/dataCollectionEndpoints@2024-03-11' = {
  name: '${prefix}-otlp'
  location: location
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

// Direct OTLP streams follow Azure Monitor's published manual-orchestration template.
resource rule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${prefix}-otlp'
  location: location
  properties: {
    dataCollectionEndpointId: endpoint.id
    references: {
      applicationInsights: [{ name: 'insights', resourceId: insights.id }]
    }
    directDataSources: {
      otelMetrics: [{
        name: 'metrics'
        streams: ['Custom-Metrics-Otel']
        enrichWithResourceAttributes: ['*']
        enrichWithReference: 'insights'
      }]
      otelLogs: [{
        name: 'logs'
        streams: ['Microsoft-OTel-Logs']
        enrichWithResourceAttributes: ['*']
        enrichWithReference: 'insights'
        replaceResourceIdWithReference: true
      }]
      otelTraces: [{
        name: 'traces'
        streams: ['Microsoft-OTel-Traces-Spans', 'Microsoft-OTel-Traces-Events', 'Microsoft-OTel-Traces-Resources']
        enrichWithResourceAttributes: ['*']
        enrichWithReference: 'insights'
        replaceResourceIdWithReference: true
      }]
    }
    destinations: {
      monitoringAccounts: [{ name: 'metrics', accountResourceId: metrics.id }]
      logAnalytics: [{ name: 'logs', workspaceResourceId: logs.id }]
    }
    dataFlows: [
      { streams: ['Custom-Metrics-Otel'], destinations: ['metrics'] }
      {
        streams: ['Microsoft-OTel-Logs', 'Microsoft-OTel-Traces-Spans', 'Microsoft-OTel-Traces-Events', 'Microsoft-OTel-Traces-Resources']
        destinations: ['logs']
      }
    ]
  }
}

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: rule
  name: guid(rule.id, gatewayPrincipalId, 'metrics-publisher')
  properties: {
    principalId: gatewayPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

#disable-next-line BCP081
resource exporter 'Microsoft.ApiManagement/aigateways/workspaces/telemetryExporters@2026-11-01' = {
  name: '${gatewayName}/default/demo-otlp'
  properties: {
    telemetryExporterType: 'OpenTelemetry'
    payloadCapture: false
    authentication: {
      managedIdentity: { resource: 'https://monitor.azure.com/' }
    }
    openTelemetry: {
      logsEndpoint: {
        url: any(insights.properties).OTLPLogsEndpoint
      }
      tracesEndpoint: {
        url: any(insights.properties).OTLPTracesEndpoint
      }
      metricsEndpoint: {
        url: any(insights.properties).OTLPMetricsEndpoint
      }
    }
    telemetry: {
      attributes: [for claim in ['tid', 'oid']: {
        source: { kind: 'claims', value: claim }
        signals: ['logs', 'traces', 'metrics']
      }]
    }
  }
}

output workspaceId string = logs.id
output workspaceCustomerId string = logs.properties.customerId
output insightsId string = insights.id
output metricsId string = any(insights.properties).AzureMonitorWorkspaceResourceId

var requests = replace(replace(replace(loadTextContent('../observability/requests.kql'),
  '__GATEWAY_ID__', resourceId('Microsoft.ApiManagement/aigateways', gatewayName)),
  '__INSIGHTS_ID__', insights.id), '__GATEWAY_HOSTNAME__', gatewayHostname)
var queryBase = {
  version: 'KqlItem/1.0'
  queryType: 0
  resourceType: 'microsoft.operationalinsights/workspaces'
  crossComponentResources: [logs.id]
  visualization: 'table'
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, gatewayName, 'demo-workbook')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'AI Gateway - teams A/B'
    category: 'workbook'
    sourceId: logs.id
    serializedData: string({
      version: 'Notebook/1.0'
      items: [
        {
          type: 1
          content: {
            json: '# AI Gateway - native telemetry\n\nLast hour only. Ingestion is delayed: use the terminal for immediate HTTP observations. Empty data is not zero traffic. Missing attributes remain unknown. Estimated model cost is not Azure billing and may be incomplete; no remaining quota is inferred. Error attribution below requires an error policy span; otherwise it is unknown. Object IDs identify synthetic workload identities A/B, not pooled team budgets.'
          }
          name: 'notice'
        }
        {
          type: 3
          name: 'health'
          content: union(queryBase, {
            title: 'Requests, native policy errors and latency by authenticated identity'
            query: '${requests}\n| summarize Requests=count(), Success=countif(HttpStatus between (200 .. 299) and StatusCode != "Error"), PolicyRejections=countif(isnotempty(RejectedPolicy)), UnattributedErrors=countif(HttpStatus >= 400 and isempty(RejectedPolicy)), p50Ms=percentile(DurationMs,50), p95Ms=percentile(DurationMs,95), LastEvent=max(TimeGenerated), MaxIngestionDelaySec=max(datetime_diff("second",IngestedAt,TimeGenerated)) by Identity\n| extend SuccessPercent=100.0*Success/Requests'
          })
        }
        {
          type: 3
          name: 'usage'
          content: union(queryBase, {
            title: 'Serving backend, observed tokens and estimated USD (missing data shown separately)'
            query: '${requests}\n| summarize Requests=count(), ObservedTokens=sum(Tokens), MissingTokenRecords=countif(isnull(Tokens)), EstimatedUsd=sum(EstimatedUsd), MissingCostRecords=countif(isnull(EstimatedUsd)) by Identity, Backend'
          })
        }
        {
          type: 3
          name: 'correlation'
          content: union(queryBase, {
            title: 'Native request correlation: compare TraceId with the terminal'
            query: '${requests}\n| order by TimeGenerated desc\n| take 200'
          })
        }
      ]
      isLocked: false
      fallbackResourceIds: [logs.id]
    })
  }
}

output workbookName string = workbook.name
