import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("workshop_console", Path(__file__).parents[1] / "console" / "server.py")
console_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(console_module)


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.console = console_module.Console(self.directory.name, {}, {
            "resourceGroupId": "/subscriptions/test/resourceGroups/demo",
            "gatewayId": "/subscriptions/test/resourceGroups/demo/providers/Microsoft.ApiManagement/aigateways/demo",
            "hostname": "demo.ai.gateway.azure.com", "insightsId": "/insights", "workbookName": "workbook",
            "callerIdentities": {"A": {"clientId": "team-a"}, "B": {"clientId": "team-b"}},
        })
        self.console.ready = True
        self.server = console_module.ThreadingHTTPServer(("127.0.0.1", 0), console_module.Handler)
        self.server.console = self.console
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.host = "127.0.0.1:" + str(self.server.server_address[1])
        self.url = "http://" + self.host

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, path, body=None, headers=None):
        request = urllib.request.Request(self.url + path, data=body, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def headers(self):
        return {"Content-Type": "application/json", "Origin": "https://" + self.host,
                "X-Demo-Csrf": self.console.csrf}

    def test_reads_cannot_launch_traffic(self):
        with patch.object(self.console, "start") as start:
            code, state = self.request("/api/state")
            self.assertEqual(code, 200)
            self.assertNotIn("DEMO_CONFIG_JSON", json.dumps(state))
            self.assertIn("price_missing=true", state["cost"]["reason"])
            start.assert_not_called()

    def test_missing_csrf_or_foreign_origin_rejected(self):
        for headers in ({}, dict(self.headers(), Origin="https://attacker.invalid"),
                        dict(self.headers(), **{"X-Demo-Csrf": "wrong"})):
            self.assertEqual(self.request("/api/run", b'{"scenario":"baseline"}', headers)[0], 403)
        self.assertEqual(self.console.jobs, [])

    def test_cost_arbitrary_commands_and_extra_fields_rejected(self):
        for value in ({"scenario": "cost-limit"}, {"scenario": "rm -rf"},
                      {"scenario": "baseline", "prompt": "not permitted"}):
            self.assertEqual(self.request("/api/run", json.dumps(value).encode(), self.headers())[0], 400)
        self.assertEqual(self.console.jobs, [])

    def test_existing_job_blocks_mutation_and_deployment(self):
        self.console.lock.acquire()
        try:
            self.assertEqual(self.request("/api/run", b'{"scenario":"baseline"}', self.headers())[0], 409)
            self.assertEqual(self.request("/api/maintenance", b"{}", self.headers())[0], 409)
            self.assertTrue(self.console.ready)
        finally:
            self.console.lock.release()

    def test_maintenance_closes_controls_without_inference(self):
        self.assertEqual(self.request("/api/maintenance", b"{}", self.headers())[0], 200)
        self.assertFalse(self.console.ready)
        self.assertEqual(self.request("/api/run", b'{"scenario":"baseline"}', self.headers())[0], 503)
        self.assertEqual(self.console.jobs, [])

    def test_launch_allowlisted_worker_once_and_throttle(self):
        with patch.object(console_module.threading, "Thread") as thread:
            code, result = self.console.start("token-rate")
            self.assertEqual(code, 202)
            self.assertEqual(self.console.jobs[0]["id"], result["id"])
            self.assertTrue(self.console.lock.locked())
            thread.assert_called_once()
            self.console.lock.release()
            self.assertEqual(self.console.start("baseline")[0], 429)

    def test_failed_worker_repairs_baseline_and_releases_lock(self):
        self.console.lock.acquire()
        job = {"id": "test-run", "scenario": "baseline", "restored": False, "error": None}
        with patch.object(console_module, "managed_token", side_effect=ValueError("rejected")), \
                patch.object(console_module.subprocess, "run") as reset:
            reset.return_value.returncode = 0
            self.console.run(job)
            self.assertEqual(job["status"], "failed")
            self.assertTrue(job["restored"])
            self.assertFalse(self.console.lock.locked())
            self.assertIn("reset-demo.ps1", " ".join(reset.call_args.args[0]))
            self.assertTrue((Path(self.directory.name) / "test-run" / "console-result.json").exists())

    def test_restoration_failure_locks_controls(self):
        self.console.lock.acquire()
        job = {"id": "test-failure", "scenario": "baseline", "restored": False, "error": None}
        with patch.object(console_module, "managed_token", side_effect=ValueError("rejected")), \
                patch.object(console_module.subprocess, "run", side_effect=OSError("reset failed")):
            self.console.run(job)
        self.assertFalse(self.console.ready)
        self.assertIn("RESTORATION FAILED", job["error"])
        self.assertFalse(self.console.lock.locked())

    def test_evidence_write_failure_is_explicit_and_releases_lock(self):
        self.console.lock.acquire()
        job = {"id": "test-storage", "scenario": "baseline", "restored": False, "error": None}
        with patch.object(console_module, "managed_token", side_effect=ValueError("rejected")), \
                patch.object(console_module.subprocess, "run") as reset, \
                patch.object(Path, "write_text", side_effect=OSError("disk full")):
            reset.return_value.returncode = 0
            self.console.run(job)
        self.assertFalse(self.console.ready)
        self.assertFalse(self.console.lock.locked())
        self.assertIn("persistence failed", job["error"])


if __name__ == "__main__":
    unittest.main()
