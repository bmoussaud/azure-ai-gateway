import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

from opentelemetry.sdk.trace.export import SpanExportResult
from opentelemetry.trace import SpanKind, StatusCode

spec = importlib.util.spec_from_file_location(
    "caller_telemetry", Path(__file__).parents[1] / "console" / "caller_telemetry.py")
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)


class CallerTelemetryTests(unittest.TestCase):
    def record(self, team="B", status=200):
        return {"team": team, "traceId": "a" * 32, "spanId": "b" * 16,
                "alias": "scenario-identity", "status": status,
                "startedAt": "2026-11-25T08:00:00+00:00",
                "endedAt": "2026-11-25T08:00:01+00:00",
                "auth.token": "must-not-escape", "prompt": "must-not-escape"}

    def test_exact_w3c_ids_and_roles_are_exported_without_payloads(self):
        for team in ("A", "B"):
            span = telemetry.measured_span(self.record(team), "demo.ai.gateway.azure.com", "demo-console", "revision")
            self.assertEqual(span.kind, SpanKind.CLIENT)
            self.assertEqual(format(span.context.trace_id, "032x"), "a" * 32)
            self.assertEqual(format(span.context.span_id, "016x"), "b" * 16)
            self.assertEqual(span.end_time - span.start_time, 1_000_000_000)
            self.assertEqual(span.resource.attributes["service.name"], f"demo-console / Application {team}")
            self.assertNotIn("must-not-escape", str(span.attributes))

    def test_http_and_transport_failure_are_not_success_spans(self):
        for code in (0, 403, 429, 503):
            span = telemetry.measured_span(self.record(status=code), "demo.ai.gateway.azure.com", "demo-console", "revision")
            self.assertEqual(span.status.status_code, StatusCode.ERROR)
        with self.assertRaises(ValueError):
            telemetry.measured_span(dict(self.record(), traceId="0"*32), "demo.ai.gateway.azure.com", "app", "rev")
        with self.assertRaises(ValueError):
            telemetry.measured_span(dict(self.record(), team="arbitrary"), "demo.ai.gateway.azure.com", "app", "rev")

    def test_ingestion_uses_managed_token_and_reports_export_failure(self):
        with patch.dict(telemetry.os.environ, {"CONTAINER_APP_NAME": "console", "CONTAINER_APP_REVISION": "revision"}):
            with patch.object(telemetry, "ManagedIdentityCredential") as identity:
                monitor = telemetry.CallerTelemetry("synthetic-connection-string", "demo.ai.gateway.azure.com", "operator-client")
                identity.assert_called_once_with(client_id="operator-client")
            with patch.object(telemetry, "AzureMonitorTraceExporter") as factory:
                factory.return_value.export.return_value = SpanExportResult.FAILURE
                with self.assertRaises(RuntimeError):
                    monitor.export([self.record()])
                self.assertEqual(factory.call_args.kwargs["credential"], monitor.credential)
                self.assertTrue(factory.call_args.kwargs["disable_offline_storage"])
                factory.return_value.shutdown.assert_called_once()
            with patch.object(telemetry, "AzureMonitorTraceExporter", side_effect=TypeError("invalid SDK option")):
                with self.assertRaisesRegex(RuntimeError, "TypeError"):
                    monitor.export([self.record()])

    def test_pinned_sdk_constructor_accepts_timeout_without_duplicate_keyword(self):
        from azure.monitor.opentelemetry.exporter.export._base import BaseExporter
        with patch.dict(telemetry.os.environ, {"CONTAINER_APP_NAME": "console", "CONTAINER_APP_REVISION": "revision"}):
            monitor = telemetry.CallerTelemetry(
                "InstrumentationKey=00000000-0000-0000-0000-000000000001;IngestionEndpoint=https://example.invalid/",
                "demo.ai.gateway.azure.com", "operator-client")
            with (patch("azure.monitor.opentelemetry.exporter.export._base.AzureMonitorClient") as client,
                  patch.object(BaseExporter, "_should_collect_stats", return_value=False),
                  patch.object(BaseExporter, "_should_collect_customer_sdkstats", return_value=False),
                  patch("azure.monitor.opentelemetry.exporter.export.trace._exporter._utils._get_application_id"),
                  patch.object(telemetry.AzureMonitorTraceExporter, "export", return_value=SpanExportResult.SUCCESS)):
                monitor.export([self.record()])
                self.assertEqual(client.call_args.kwargs["connection_timeout"], 20)
