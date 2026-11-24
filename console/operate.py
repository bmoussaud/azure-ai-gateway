"""Privileged exec helpers. No token, cookie, CSRF value, or header is printed."""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

from server import managed_token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def maintenance():
    origin = "https://127.0.0.1:8080"
    with urllib.request.urlopen("http://127.0.0.1:8080/api/state", timeout=30) as response:
        state = json.load(response)
    request = urllib.request.Request("http://127.0.0.1:8080/api/maintenance", data=b"",
                                    headers={"Origin": origin, "X-Demo-Csrf": state["csrf"]})
    with urllib.request.urlopen(request, timeout=30) as response:
        if not json.load(response).get("maintenance"):
            raise RuntimeError("Maintenance was not confirmed")
    print("MAINTENANCE_READY", flush=True)


def accept(live_only=False):
    config = json.loads(os.environ["DEMO_CONFIG_JSON"])
    state = json.loads(os.environ["DEMO_STATE_JSON"])
    origin = config["consoleUrl"]
    parsed = urllib.parse.urlsplit(origin)
    if (parsed.scheme != "https" or not parsed.hostname
            or not parsed.hostname.startswith(config["gatewayName"] + "-console.")
            or not parsed.hostname.endswith(".azurecontainerapps.io")
            or parsed.username or parsed.port or parsed.path not in ("", "/")):
        raise ValueError("Unexpected console origin")
    opener = urllib.request.build_opener(NoRedirect)
    statuses = {}
    for label, credential in (("anonymous", None), ("wrongPrincipal", managed_token(
            state["callerIdentities"]["A"]["clientId"], os.environ["CONSOLE_AUTH_RESOURCE"]))):
        headers = {"Authorization": "Bearer " + credential} if credential else {}
        try:
            with opener.open(urllib.request.Request(origin + "/api/state", headers=headers), timeout=30) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
        statuses[label] = status
    if statuses["anonymous"] not in (302, 401) or statuses["wrongPrincipal"] != 403:
        raise RuntimeError("Native authentication/authorization denial was not observed: " + json.dumps(statuses))
    env = dict(os.environ, DEMO_CONSOLE_TOKEN=managed_token(
        os.environ["OPERATOR_CLIENT_ID"], os.environ["CONSOLE_AUTH_RESOURCE"]))
    subprocess.run(["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/scripts/verify-console.ps1",
                    "-Url", origin, "-OutputPath", "/tmp/console-acceptance.json",
                    *(["-LiveBaselineOnly"] if live_only else [])], env=env, check=True)
    evidence_path = Path("/tmp/console-acceptance.json")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8-sig"))
    evidence["nativeAuthentication"] = statuses
    evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
    print("CONSOLE_ACCEPTANCE_VERIFIED", flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["maintenance"]:
        maintenance()
    elif sys.argv[1:] == ["accept"]:
        accept()
    elif sys.argv[1:] == ["accept-live"]:
        accept(live_only=True)
    else:
        raise ValueError("Expected maintenance, accept or accept-live")
