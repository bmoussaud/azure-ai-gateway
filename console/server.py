"""Single-process workshop console behind native authenticated/restricted ingress."""
import copy
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = frozenset(("baseline", "weighted-routing", "failover", "identity-routing", "token-rate", "token-quota", "reset"))


def complete_records(path):
    # One snapshot: a trailing partial write (including a split UTF-8 character) waits until next poll.
    data = path.read_bytes()
    return [json.loads(line) for line in data.split(b"\n")[:-1] if line.strip()]


def managed_token(client_id, resource):
    endpoint = os.environ["IDENTITY_ENDPOINT"]
    query = urllib.parse.urlencode({"api-version": "2019-08-01", "client_id": client_id, "resource": resource})
    request = urllib.request.Request(endpoint + "?" + query,
                                    headers={"X-IDENTITY-HEADER": os.environ["IDENTITY_HEADER"]})
    with urllib.request.urlopen(request, timeout=30) as response:
        credential = json.load(response)
    if (credential.get("resource", "").rstrip("/") != resource.rstrip("/")
            or int(credential.get("expires_on", 0)) <= time.time() + 120
            or credential.get("client_id", client_id).lower() != client_id.lower()):
        raise ValueError("Managed identity credential metadata rejected")
    return credential["access_token"]


class Console:
    def __init__(self, data, config, state):
        self.data = Path(data)
        self.data.mkdir(parents=True, exist_ok=True)
        self.config = config
        self.state = state
        self.lock = threading.Lock()
        self.guard = threading.RLock()
        self.stop_signal = threading.Event()
        self.csrf = secrets.token_urlsafe(32)
        self.jobs = []
        self.last_start = 0.0
        self.ready = False
        self.error = None
        self.config_path = self.data / "config.local.json"
        self.state_path = self.data / "state.json"
        self.config_path.write_text(json.dumps(config), encoding="utf-8")
        self.state_path.write_text(json.dumps(state), encoding="utf-8")
        self.env = dict(os.environ, DEMO_STATE_PATH=str(self.state_path))

    def command(self, script, *args):
        return ["pwsh", "-NoLogo", "-NoProfile", "-File", str(ROOT / "scripts" / script),
                "-ConfigPath", str(self.config_path), *map(str, args)]

    def initialize(self):
        try:
            login = ["az", "login", "--identity", "--client-id", os.environ["OPERATOR_CLIENT_ID"],
                     "--allow-no-subscriptions", "--output", "none", "--only-show-errors"]
            subprocess.run(login, env=self.env, check=True, timeout=90, stdout=subprocess.DEVNULL)
            # Repair recognized lab faults after a container restart before admitting new scenarios.
            subprocess.run(self.command("reset-demo.ps1"), env=self.env, check=True, timeout=360)
            self.ready = True
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.error = "Initialization failed; inspect dedicated Container App logs."
            print(type(error).__name__ + ": console initialization failed", flush=True)

    def start(self, scenario):
        if scenario not in SCENARIOS:
            return 400, {"error": "Unsupported scenario. Cost remains non-qualified and disabled."}
        if not self.ready:
            return 503, {"error": self.error or "Initializing managed identity and restoring baseline."}
        if not self.lock.acquire(blocking=False):
            return 409, {"error": "One scenario is already running. No traffic was added."}
        if not self.ready:
            self.lock.release()
            return 503, {"error": "Console is in deployment maintenance."}
        if time.monotonic() - self.last_start < 10:
            self.lock.release()
            return 429, {"error": "Please wait ten seconds between scenario launches."}
        self.last_start = time.monotonic()
        job = {"id": uuid.uuid4().hex, "scenario": scenario, "status": "configuring",
               "startedAt": time.time(), "requests": [], "native": [], "activity": [], "error": None,
               "clientRetries": 0, "concurrency": 1, "restored": False, "stopRequested": False,
               "requestCeiling": None, "minimumSpacingSeconds": None, "finishedAt": None}
        self.note(job, "accepted")
        with self.guard:
            self.stop_signal.clear()
            self.jobs = (self.jobs + [job])[-20:]
        threading.Thread(target=self.run, args=(job,), daemon=True).start()
        return 202, {"id": job["id"]}

    def stop(self, job_id):
        with self.guard:
            job = self.jobs[-1] if self.jobs else None
            if not job or job["id"] != job_id or job["scenario"] == "reset":
                return 409, {"error": "Aucun scénario interruptible ne correspond à cette exécution."}
            if job["status"] == "stopped":
                return 200, {"id": job_id}
            if job["status"] not in ("configuring", "running", "awaiting-native"):
                return 409, {"error": "Cette exécution est déjà terminée."}
            if not job["stopRequested"]:
                try:
                    directory = self.data / job["id"]
                    directory.mkdir(exist_ok=True)
                    (directory / "stop.requested").touch()
                except OSError:
                    return 503, {"error": "Impossible de transmettre l’arrêt au scénario."}
                job["stopRequested"] = True
                self.note(job, "stop-requested")
                self.stop_signal.set()
            return 202, {"id": job_id}

    def note(self, job, kind, **fields):
        with self.guard:
            job.setdefault("activity", []).append({"at": time.time(), "kind": kind, **fields})

    def observe(self, job, directory, seen):
        activity = directory / "activity.jsonl"
        if activity.exists():
            records = complete_records(activity)
            with self.guard:
                job["activity"].extend(records[seen:])
                seen = len(records)
        events = directory / "events.jsonl"
        if events.exists():
            requests = complete_records(events)
            with self.guard:
                job["requests"] = requests
                job["status"] = "running"
        return seen

    def run(self, job):
        directory = self.data / job["id"]
        try:
            directory.mkdir(exist_ok=True)
            env = dict(self.env)
            if job["scenario"] != "reset":
                self.note(job, "identities")
                for team in ("A", "B"):
                    if self.stop_signal.is_set():
                        return
                    env[f"DEMO_TEAM_{team}_TOKEN"] = managed_token(
                        self.state["callerIdentities"][team]["clientId"], "https://ai.gateway.azure.com")
            else:
                self.note(job, "restoring")
            with (directory / "worker.log").open("w", encoding="utf-8") as log:
                process = subprocess.Popen(self.command("console-worker.ps1", "-Scenario", job["scenario"],
                                                       "-OutputDirectory", directory),
                                           env=env, stdout=log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 1800
                seen = 0
                while process.poll() is None:
                    seen = self.observe(job, directory, seen)
                    if time.monotonic() > deadline:
                        process.terminate()
                        try:
                            process.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                        raise TimeoutError("Scenario exceeded its thirty-minute server bound")
                    time.sleep(1)
                self.observe(job, directory, seen)
                results = list(directory.glob("*.json"))
                run = next((p for p in results if len(p.stem) == 32), None)
                if run:
                    observed = json.loads(run.read_text(encoding="utf-8-sig"))
                    job["restored"] = not observed["restorationFailures"]
                    job["requestCeiling"] = observed["requestCeiling"]
                    job["minimumSpacingSeconds"] = observed["minimumInterRequestSpacingSeconds"]
                if process.returncode:
                    raise RuntimeError("Scenario assertion failed. HTTP evidence retained; not certified.")
                if self.stop_signal.is_set():
                    return
                if job["scenario"] == "reset":
                    job.update(status="complete", restored=True)
                    self.note(job, "restored")
                    return
                job["status"] = "awaiting-native"
                self.note(job, "awaiting-traces")
                for _ in range(30):
                    if self.stop_signal.is_set():
                        return
                    query = subprocess.run(self.command("console-native.ps1", "-EventsPath", directory / "events.jsonl",
                                                        "-OutputPath", directory / "native.json"),
                                           env=self.env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
                    if query.returncode:
                        raise RuntimeError("Native telemetry query failed; inspect operator read permissions.")
                    native = json.loads((directory / "native.json").read_text(encoding="utf-8-sig"))
                    if len(native) != len(job["native"]):
                        self.note(job, "traces", count=len(native), total=len(job["requests"]))
                    job["native"] = native
                    if self.stop_signal.is_set():
                        return
                    if len(job["native"]) == len(job["requests"]):
                        self.note(job, "verifying")
                        verified = subprocess.run(self.command("verify-results.ps1", "-ResultsPath", run),
                                                  env=self.env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
                        if verified.returncode:
                            raise RuntimeError("Native scenario assertions failed; HTTP alone is not certification.")
                        with self.guard:
                            if not self.stop_signal.is_set():
                                job["status"] = "verified"
                                self.note(job, "verified")
                        return
                    if self.stop_signal.wait(15):
                        return
                raise TimeoutError("Native ingestion not complete after bounded read-only verification.")
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            job["status"] = "failed"
            self.note(job, "failed")
            job["error"] = str(error) if isinstance(error, (RuntimeError, TimeoutError)) else type(error).__name__
            print(f"Job {job['id']} failed: {job['error']}", flush=True)
        finally:
            # Even a killed worker must not leave the live gateway in a fault/governance profile.
            if not job["restored"]:
                self.note(job, "repair")
                try:
                    repair = subprocess.run(self.command("reset-demo.ps1"), env=self.env, check=True, timeout=360)
                    job["restored"] = repair.returncode == 0
                    self.note(job, "restored")
                except (OSError, subprocess.SubprocessError):
                    job["status"] = "failed"
                    job["error"] = "BASELINE RESTORATION FAILED. Controls locked; operator reset required."
                    self.ready = False
                    self.note(job, "repair-failed")
            job["finishedAt"] = time.time()
            try:
                with self.guard:
                    if job.get("stopRequested") and job["status"] != "failed" and job["restored"]:
                        job["status"] = "stopped"
                        self.note(job, "stopped")
                    (directory / "console-result.json").write_text(json.dumps(job), encoding="utf-8")
            except OSError as error:
                job["status"] = "failed"
                job["error"] = "Evidence persistence failed; controls locked. Inspect container storage."
                self.ready = False
                self.note(job, "storage-failed")
                print(f"Job {job['id']}: evidence write failed ({type(error).__name__})", flush=True)
            finally:
                self.lock.release()

    def snapshot(self):
        group = self.state["resourceGroupId"]
        gateway = self.state["gatewayId"]
        return {"ready": self.ready, "error": self.error, "busy": self.lock.locked(), "csrf": self.csrf,
                "jobs": copy.deepcopy(self.jobs), "gateway": self.state["hostname"],
                "links": {
                    "gateway": "https://ai.gateway.azure.com" + gateway + "/workspaces/default/monitoring",
                    "insights": "https://portal.azure.com/#resource" + self.state["insightsId"],
                    "workbook": "https://portal.azure.com/#resource" + group
                    + "/providers/Microsoft.Insights/workbooks/" + self.state["workbookName"]},
                "cost": {"qualified": False, "reason": "price_missing=true: limite de cout non qualifiee"},
                "security": ("Connexion Entra requise : utilisateur autorise et identite operateur dediee uniquement."
                             if os.environ.get("DEMO_AUTH_MODE") == "entra"
                             else "Ingress limite a l'IPv4 de l'operateur; identites Azure cote serveur uniquement.")}


class Handler(BaseHTTPRequestHandler):
    server_version = "WorkshopConsole"

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, fmt, *args):
        # Do not log request headers, cookies, tokens, or arbitrary query strings.
        print(f"HTTP {self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}", flush=True)

    def send(self, code, payload, content_type="application/json"):
        data = json.dumps(payload).encode() if content_type == "application/json" else payload
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                         "style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/app-a", "/app-b"):
            self.send(200, (ROOT / "console" / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/api/state":
            with self.server.console.guard:
                self.send(200, self.server.console.snapshot())
        elif path == "/health":
            self.send(200, {"running": True})
        else:
            self.send(404, {"error": "Not found"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 128 or self.headers.get("Transfer-Encoding"):
                raise ValueError("Invalid request framing")
            raw = self.rfile.read(length)
        except ValueError:
            self.send(400, {"error": "Only bounded, non-streaming JSON requests are accepted."})
            return
        origin = self.headers.get("Origin", "")
        host = self.headers.get("Host", "")
        expected = "https://" + host
        if (origin != expected or not hmac.compare_digest(self.headers.get("X-Demo-Csrf", ""),
                                                         self.server.console.csrf)):
            self.send(403, {"error": "Same-origin console action and CSRF header required."})
            return
        if self.path == "/api/maintenance":
            console = self.server.console
            if not console.lock.acquire(blocking=False):
                self.send(409, {"error": "A scenario is running. Deployment must wait."})
                return
            try:
                console.ready = False
                console.error = "Deploiement en cours; aucune nouvelle execution autorisee."
                self.send(200, {"maintenance": True})
            finally:
                console.lock.release()
            return
        if self.path not in ("/api/run", "/api/stop"):
            self.send(404, {"error": "Not found"})
            return
        try:
            if length < 2 or length > 128 or self.headers.get_content_type() != "application/json":
                raise ValueError("Expected bounded JSON")
            body = json.loads(raw)
            field = "scenario" if self.path == "/api/run" else "id"
            if not isinstance(body, dict) or set(body) != {field} or not isinstance(body[field], str):
                raise ValueError("Unexpected action payload")
        except (ValueError, json.JSONDecodeError):
            self.send(400, {"error": "Invalid scenario action payload."})
            return
        console = self.server.console
        code, result = console.start(body["scenario"]) if field == "scenario" else console.stop(body["id"])
        self.send(code, result)


if __name__ == "__main__":
    config = json.loads(os.environ["DEMO_CONFIG_JSON"])
    state = json.loads(os.environ["DEMO_STATE_JSON"])
    console = Console("/tmp/demo-console", config, state)
    threading.Thread(target=console.initialize, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.console = console
    server.serve_forever()
