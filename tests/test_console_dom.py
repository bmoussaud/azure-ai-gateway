"""Optional Chromium DOM checks with synthetic API responses, never Azure traffic."""
import json
from pathlib import Path
import unittest

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None


@unittest.skipIf(sync_playwright is None, "Install the existing optional Playwright tooling for DOM checks")
class ConsoleDomTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True)
        cls.html = (Path(__file__).parents[1] / "console" / "index.html").read_text(encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def test_start_clears_all_previous_graph_state_before_new_model_is_loaded(self):
        page = self.browser.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        old = {
            "id": "previous", "scenario": "identity-routing", "status": "verified",
            "startedAt": 1, "finishedAt": 2, "restored": True, "error": None,
            "alias": "scenario-identity", "configurationUnchanged": True,
            "requests": [{"traceId": "old-trace", "team": "B", "status": 200,
                          "alias": "scenario-identity", "phase": "identity-healthy",
                          "usage": {"total_tokens": 17}, "latencyMs": 20}],
            "native": [{"TraceId": "old-trace", "Backend": "backend-2/demo-model"}],
            "activity": [{"kind": "model-selected", "at": 1, "config": {
                "routes": [{"alias": "scenario-identity", "targets": [
                    {"backend": 1, "priority": 0, "weight": 1, "when": "@cel(validated_identity)"},
                    {"backend": 2, "priority": 1, "weight": 1}]}],
                "failures": [], "policies": [], "maxRetryAttempts": 0}},
                {"kind": "verified", "at": 2}],
        }
        state = {"ready": True, "busy": False, "error": None, "csrf": "synthetic",
                 "security": "Synthetic DOM fixture, not Azure evidence",
                 "jobs": [old], "links": {}}

        def respond(route):
            if route.request.url.endswith("/api/state"):
                route.fulfill(json=state)
            elif route.request.url.endswith("/api/run"):
                route.fulfill(status=202, json={"id": "new-run"})
            else:
                route.fulfill(content_type="text/html", body=self.html)

        page.route("https://console.invalid/**", respond)
        try:
            page.goto("https://console.invalid/")
            page.wait_for_selector("#viz-proof-layer path")
            self.assertEqual(page.locator("#viz-identity-lock").get_attribute("visibility"), "visible")
            page.evaluate("""() => {
                el("viz-meters").append(node("div","old meter"));
                el("viz-backend-1").classList.add("is-down");
                el("viz-backend-1-state").classList.add("is-confirmed","is-down");
            }""")
            page.select_option("#scenario", "token-rate")
            page.click("#start")
            page.wait_for_function("awaitingJob === 'new-run'")
            clean = page.evaluate("""() => ({
                routes:el("viz-route-layer").childElementCount,
                proofs:el("viz-proof-layer").childElementCount,
                calls:el("viz-call-layer").childElementCount,
                meters:el("viz-meters").childElementCount,
                steps:el("viz-steps").childElementCount,
                lock:el("viz-identity-lock").getAttribute("visibility"),
                packets:["A","B"].every(t=>el(`viz-packet-${t}`).hidden),
                states:[1,2].every(b=>!el(`viz-backend-${b}`).classList.contains("is-down") &&
                    !el(`viz-backend-${b}-state`).classList.contains("is-confirmed")),
                rows:el("rows-A").childElementCount+el("rows-B").childElementCount,
                oldTrace:el("gateway-viz").textContent.includes("old-trace")
            })""")
            self.assertEqual(clean, {"routes": 0, "proofs": 0, "calls": 0, "meters": 0, "steps": 0,
                                     "lock": "hidden", "packets": True, "states": True,
                                     "rows": 0, "oldTrace": False})
            page.evaluate("""() => {
                state.jobs.push({id:"new-run",scenario:"token-rate",status:"configuring",startedAt:3,
                    restored:true,requests:[],native:[],error:null,activity:[{kind:"model-selected",at:3,
                    config:{routes:[{alias:"scenario-token-rate",targets:[
                        {backend:1,priority:0,weight:1},{backend:2,priority:1,weight:1}]}],
                        policies:[{type:"tokenLimit",count:256,period:"minute",
                            scope:"resource",counterKey:["identity"]}],failures:[],maxRetryAttempts:0}}]});
                render();
            }""")
            self.assertIn("scenario-token-rate", page.locator("#viz-alias").text_content())
            self.assertEqual(page.locator("#viz-proof-layer path").count(), 0)
            self.assertEqual(page.locator("#viz-meters .viz-meter").count(), 2)
            self.assertEqual(page.locator("#viz-identity-lock").get_attribute("visibility"), "hidden")
            self.assertFalse(errors, json.dumps(errors))
        finally:
            page.close()


if __name__ == "__main__":
    unittest.main()
