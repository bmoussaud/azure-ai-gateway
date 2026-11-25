"""Optional Chromium DOM checks with synthetic API responses, never Azure traffic."""
import json
import os
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

    def caller_page(self, reduced_motion="no-preference"):
        page = self.browser.new_page(reduced_motion=reduced_motion, viewport={"width": 1440, "height": 1200})
        page.add_init_script("""const schedule=window.setTimeout;
            window.setTimeout=(callback,...args)=>callback?.name==="poll"?0:schedule(callback,...args);""")
        state = {"ready": True, "busy": True, "error": None, "csrf": "synthetic",
                 "security": "API synthétique : contrôle DOM, pas une preuve Azure",
                 "jobs": [{"id": "caller-run", "scenario": "identity-routing", "status": "running",
                           "startedAt": 1, "requests": [], "native": [], "error": None,
                           "activity": [{"kind": "model-selected", "at": 1, "config": {
                               "routes": [{"alias": "scenario-identity", "targets": [
                                   {"backend": 1, "priority": 0, "weight": 1, "when": "@cel(identity)"},
                                   {"backend": 2, "priority": 1, "weight": 1}]}],
                               "failures": [], "policies": [], "maxRetryAttempts": 0}}]}], "links": {}}
        page.route("https://console.invalid/**", lambda route: route.fulfill(json=state)
                   if route.request.url.endswith("/api/state")
                   else route.fulfill(content_type="text/html", body=self.html))
        page.goto("https://console.invalid/")
        page.wait_for_function("state?.jobs.length === 1")
        return page

    def test_actual_source_same_source_calls_and_deferred_per_call_trace(self):
        page = self.caller_page()
        try:
            page.evaluate("""() => {
                state.jobs[0].activity.push({kind:"sending",at:2,team:"B",number:1,alias:"scenario-identity"});
                render();
            }""")
            self.assertIn("En cours · appel 1 · Application B", page.locator("#viz-caller-status").inner_text())
            self.assertEqual(page.locator(".viz-wire.is-current").count(), 1)
            self.assertIn("is-current", page.locator("#viz-wire-B").get_attribute("class"))
            self.assertNotIn("is-source", page.locator("#viz-app-A").get_attribute("class"))
            self.assertIn("non encore prouvé", page.locator("#viz-caller-proof").inner_text())
            page.evaluate("""() => {
                state.jobs[0].requests.push({team:"B",alias:"scenario-identity",traceId:"trace-b1",status:200});
                state.jobs[0].activity.push({kind:"responded",at:3,team:"B",number:1,alias:"scenario-identity",status:200},
                    {kind:"sending",at:4,team:"B",number:2,alias:"scenario-identity"});
                render();
            }""")
            self.assertIn("appel 2 · Application B", page.locator("#viz-caller-status").inner_text())
            self.assertEqual(page.locator("#viz-caller-log li").count(), 2)
            animation = page.evaluate("el('viz-wire-B').getAnimations()[0].startTime")
            page.evaluate("render()")
            self.assertEqual(animation, page.evaluate("el('viz-wire-B').getAnimations()[0].startTime"))
            page.evaluate("""() => {
                state.jobs[0].native.push({TraceId:"trace-b1",Backend:"backend-2/demo-model"});
                render();
            }""")
            self.assertIn("non encore prouvé", page.locator("#viz-caller-proof").inner_text())
            self.assertNotIn("trace-b1", page.locator("#viz-caller-proof").inner_text())
            self.assertIn("trace-b1", page.locator('#viz-caller-log [data-number="1"]').inner_text())
            page.evaluate("""() => {
                state.jobs[0].requests.push({team:"B",alias:"scenario-identity",traceId:"trace-b2",status:200});
                state.jobs[0].activity.push({kind:"responded",at:5,team:"B",number:2,alias:"scenario-identity",status:200},
                    {kind:"sending",at:6,team:"A",number:3,alias:"scenario-identity"});
                render();
            }""")
            self.assertIn("appel 3 · Application A", page.locator("#viz-caller-status").inner_text())
            self.assertNotIn("is-current", page.locator("#viz-wire-B").get_attribute("class"))
            self.assertIn("is-current", page.locator("#viz-wire-A").get_attribute("class"))
            self.assertEqual(page.locator("#viz-caller-log li").count(), 3)
            page.evaluate("""() => {
                state.jobs[0].stopRequested=true;render();
            }""")
            self.assertIn("arrêt demandé", page.locator("#viz-caller-status").inner_text())
            directory = os.environ.get("DEMO_DOM_SCREENSHOT_DIRECTORY")
            if directory:
                Path(directory).mkdir(parents=True, exist_ok=True)
                page.locator("#gateway-viz").screenshot(path=str(Path(directory) / "caller-source-synthetic.png"))
            page.evaluate("""() => {
                state.jobs[0].activity.push({kind:"stopped",at:7});state.jobs[0].status="stopped";render();
            }""")
            self.assertEqual(page.locator(".viz-wire.is-current").count(), 0)
            self.assertIn("Dernier appel observé", page.locator("#viz-caller-status").inner_text())
            page.evaluate("""() => {
                state.jobs.push({id:"new",scenario:"baseline",status:"configuring",startedAt:8,
                    requests:[],native:[],activity:[],error:null});selected="new";render();
            }""")
            self.assertEqual(page.locator("#viz-caller-log li").count(), 0)
            self.assertEqual(page.locator(".viz-app.is-source").count(), 0)
            self.assertEqual(page.locator("#viz-caller-status").inner_text(), "Aucun appel affiché")
        finally:
            page.close()

    def test_poll_batch_is_history_not_delayed_live_and_replay_keeps_source(self):
        page = self.caller_page(reduced_motion="reduce")
        try:
            page.evaluate("""() => {
                const j=state.jobs[0];
                j.activity.push({kind:"sending",at:2,team:"A",number:1,alias:"scenario-identity"},
                    {kind:"responded",at:3,team:"A",number:1,alias:"scenario-identity",status:200},
                    {kind:"sending",at:4,team:"B",number:2,alias:"scenario-identity"},
                    {kind:"responded",at:5,team:"B",number:2,alias:"scenario-identity",status:200});
                j.requests=[{team:"A",alias:"scenario-identity",traceId:"a",status:200},
                    {team:"B",alias:"scenario-identity",traceId:"b",status:200}];
                j.native=[{TraceId:"a",Backend:"backend-1/demo-model"},{TraceId:"b",Backend:"backend-2/demo-model"}];
                j.status="verified";j.activity.push({kind:"traces",at:6,count:2});state.busy=false;render();
            }""")
            self.assertEqual(page.locator("#viz-caller-log li").count(), 2)
            self.assertIn("Dernier appel observé · appel 2 · Application B", page.locator("#viz-caller-status").inner_text())
            self.assertEqual(page.locator(".viz-wire.is-current").count(), 0)
            snapshot = page.evaluate("state")
            page.unroute("https://console.invalid/**")
            page.route("https://console.invalid/**", lambda route: route.fulfill(json=snapshot)
                       if route.request.url.endswith("/api/state")
                       else route.fulfill(content_type="text/html", body=self.html))
            page.reload()
            page.wait_for_function("state?.jobs.length === 1")
            self.assertIn("Dernier appel observé · appel 2 · Application B", page.locator("#viz-caller-status").inner_text())
            self.assertEqual(page.locator("#viz-caller-log li").count(), 2)
            self.assertEqual(page.locator(".viz-wire.is-current").count(), 0)
            page.evaluate("""() => {
                replayState={jobId:"caller-run",cursor:1,playing:true,speed:4};render();
            }""")
            self.assertIn("REJEU enregistré · appel 1 · Application A", page.locator("#viz-caller-status").inner_text())
            self.assertEqual(page.locator("#viz-caller-log li").count(), 1)
            self.assertNotIn("Backend prouvé", page.locator("#viz-caller-proof").inner_text())
            self.assertEqual(page.locator("#viz-wire-A").evaluate("(e)=>getComputedStyle(e).animationName"), "none")
            page.evaluate("replayState.cursor=3;render()")
            self.assertIn("appel 2 · Application B", page.locator("#viz-caller-status").inner_text())
            self.assertIn("is-source", page.locator("#viz-app-B").get_attribute("class"))
            page.evaluate("replayState.cursor=5;render()")
            self.assertIn("backend-2/demo-model · trace b", page.locator("#viz-caller-proof").inner_text())
            page.evaluate("""() => {
                replayState=null;
                const j=state.jobs[0];
                for(let number=3;number<=10;number++)j.activity.push({
                    kind:"sending",at:6+number,team:"A",number,alias:"scenario-identity"});
                render();
                replayState={jobId:j.id,cursor:1,playing:false,speed:1};render();
            }""")
            self.assertEqual(page.locator("#viz-caller-log li").count(), 1)
            self.assertEqual(page.locator("#viz-caller-log li").get_attribute("data-number"), "1")
            self.assertNotIn("Backend prouvé", page.locator("#viz-caller-log").inner_text())
            page.evaluate("replayState.cursor=state.jobs[0].activity.length-1;render()")
            self.assertEqual(page.locator("#viz-caller-log li").evaluate_all(
                "(items)=>items.map(item=>item.dataset.number)"),
                [str(number) for number in range(1, 11)])
            page.evaluate("replayState.cursor=3;render()")
            self.assertEqual(page.locator("#viz-caller-log li").evaluate_all(
                "(items)=>items.map(item=>item.dataset.number)"), ["1", "2"])
            self.assertNotIn("Backend prouvé", page.locator("#viz-caller-log").inner_text())
        finally:
            page.close()

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
                oldTrace:el("gateway-viz").textContent.includes("old-trace"),
                callers:el("viz-caller-log").childElementCount,
                sources:document.querySelectorAll(".viz-app.is-source,.viz-wire.is-current").length
            })""")
            self.assertEqual(clean, {"routes": 0, "proofs": 0, "calls": 0, "meters": 0, "steps": 0,
                                     "lock": "hidden", "packets": True, "states": True,
                                     "rows": 0, "oldTrace": False, "callers": 0, "sources": 0})
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
