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

    def test_stop_is_scoped_protected_and_idempotent_then_restores(self):
        with patch.object(console_module.threading, "Thread"):
            _, result = self.console.start("weighted-routing")
        job = self.console.jobs[-1]
        payload = json.dumps(result).encode()
        marker = self.console.data / result["id"] / "stop.requested"
        self.assertEqual(self.request("/api/stop", payload, {})[0], 403)
        self.assertEqual(self.request("/api/stop", b'{"id":"old-run"}', self.headers())[0], 409)
        self.assertFalse(marker.exists())
        for _ in range(2):
            self.assertEqual(self.request("/api/stop", payload, self.headers())[0], 202)
        self.assertTrue(marker.exists())
        self.assertEqual([e["kind"] for e in job["activity"]].count("stop-requested"), 1)
        self.assertEqual(self.console.start("baseline")[0], 409)
        with patch.object(console_module, "managed_token") as token, \
                patch.object(console_module.subprocess, "run") as repair:
            repair.return_value.returncode = 0
            self.console.run(job)
            token.assert_not_called()
            repair.assert_called_once()
        self.assertEqual(job["status"], "stopped")
        self.assertTrue(job["restored"])
        self.assertFalse(self.console.lock.locked())
        self.assertEqual(self.console.stop(job["id"])[0], 200)

    def test_reset_cannot_be_cancelled(self):
        with patch.object(console_module.threading, "Thread"):
            _, result = self.console.start("reset")
        self.assertEqual(self.console.stop(result["id"])[0], 409)
        self.assertFalse(self.console.stop_signal.is_set())
        self.console.lock.release()

    def test_restoration_failure_locks_controls(self):
        self.console.lock.acquire()
        job = {"id": "test-failure", "scenario": "baseline", "restored": False, "error": None}
        with patch.object(console_module, "managed_token", side_effect=ValueError("rejected")), \
                patch.object(console_module.subprocess, "run", side_effect=OSError("reset failed")):
            self.console.run(job)
        self.assertFalse(self.console.ready)
        self.assertIn("RESTORATION FAILED", job["error"])
        self.assertFalse(self.console.lock.locked())

    def test_activity_reaches_snapshot_before_http_and_partial_rows_are_not_replayed(self):
        job = {"activity": [], "requests": [], "native": []}
        self.console.jobs.append(job)
        directory = Path(self.directory.name)
        path = directory / "activity.jsonl"
        sending = {"kind": "sending", "team": "A", "number": 1, "at": 1}
        responded = {"kind": "responded", "status": 200, "at": 2}
        response = json.dumps(responded).encode()
        path.write_bytes(json.dumps(sending).encode() + b"\n" + response[:8])
        seen = self.console.observe(job, directory, 0)
        first = self.request("/api/state")[1]["jobs"][0]
        self.assertEqual(first, {"activity": [sending], "requests": [], "native": []})
        with path.open("ab") as f:
            f.write(response[8:] + b"\n")
        (directory / "events.jsonl").write_bytes(b'{"status":200}\n')
        seen = self.console.observe(job, directory, seen)
        self.console.observe(job, directory, seen)
        self.assertEqual(job["activity"], [sending, responded])
        self.assertEqual(job["requests"], [{"status": 200}])
        self.assertEqual(job["native"], [])

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
