"""Export measured ACA PowerShell HTTP spans, preserving their W3C IDs."""
from datetime import datetime
import os
import re

from azure.identity import ManagedIdentityCredential
from azure.core.exceptions import AzureError
from azure.monitor.opentelemetry.exporter import AzureMonitorTraceExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan
from opentelemetry.sdk.trace.export import SpanExportResult
from opentelemetry.sdk.util.instrumentation import InstrumentationScope
from opentelemetry.trace import SpanContext, SpanKind, Status, StatusCode, TraceFlags


def measured_span(record, hostname, app_name, revision):
    if (record["team"] not in ("A", "B")
            or not re.fullmatch(r"[0-9a-f]{32}", record["traceId"])
            or not re.fullmatch(r"[0-9a-f]{16}", record["spanId"])
            or not int(record["traceId"], 16) or not int(record["spanId"], 16)
            or not re.fullmatch(r"[a-z0-9-]+", record["alias"])):
        raise ValueError("Invalid measured caller span identifiers")
    start = int(datetime.fromisoformat(record["startedAt"]).timestamp() * 1_000_000_000)
    end = int(datetime.fromisoformat(record["endedAt"]).timestamp() * 1_000_000_000)
    if end < start or not 0 <= record["status"] <= 599:
        raise ValueError("Invalid measured caller span timing or HTTP status")
    attributes = {
        "http.request.method": "POST", "server.address": hostname, "server.port": 443,
        "url.full": f"https://{hostname}/default/models/openai/v1/chat/completions",
        "demo.application": record["team"], "gen_ai.request.model": record["alias"],
        "demo.emitter": "ACA PowerShell HttpClient",
    }
    if record["status"]:
        attributes["http.response.status_code"] = record["status"]
    else:
        attributes["error.type"] = "transport_error"
    return ReadableSpan(
        name="POST /default/models/openai/v1/chat/completions",
        context=SpanContext(int(record["traceId"], 16), int(record["spanId"], 16),
                            is_remote=False, trace_flags=TraceFlags(TraceFlags.SAMPLED)),
        kind=SpanKind.CLIENT, start_time=start, end_time=end,
        status=Status(StatusCode.ERROR if record["status"] == 0 or record["status"] >= 400
                      else StatusCode.UNSET),
        attributes=attributes,
        resource=Resource.create({
            "service.name": f"{app_name} / Application {record['team']}",
            "service.namespace": "azure-ai-gateway-demo", "service.version": revision,
            "service.instance.id": os.environ.get("CONTAINER_APP_REPLICA_NAME", app_name),
            "deployment.environment": "workshop", "cloud.provider": "azure",
            "cloud.platform": "azure_container_apps", "azure.containerapps.name": app_name,
        }),
        instrumentation_scope=InstrumentationScope("demo.powershell.http", "1.0.0"),
    )


class CallerTelemetry:
    def __init__(self, connection_string, hostname, client_id):
        self.connection_string, self.hostname = connection_string, hostname
        self.credential = ManagedIdentityCredential(client_id=client_id)
        self.app_name = os.environ["CONTAINER_APP_NAME"]
        self.revision = os.environ["CONTAINER_APP_REVISION"]

    def export(self, records):
        if not records:
            return
        spans = [measured_span(r, self.hostname, self.app_name, self.revision) for r in records]
        exporter = None
        try:
            exporter = AzureMonitorTraceExporter(
                connection_string=self.connection_string, credential=self.credential,
                disable_offline_storage=True, timeout=20, read_timeout=20,
            )
            if exporter.export(spans) != SpanExportResult.SUCCESS:
                raise RuntimeError("Caller telemetry export failed; HTTP evidence is not map certification.")
        except (AzureError, TypeError, ValueError) as error:
            raise RuntimeError(f"Caller telemetry export failed ({type(error).__name__}).") from error
        finally:
            if exporter is not None:
                exporter.shutdown()
