"""Measure four legitimate core flows at a fixed offered load before and during a Genesis outage.

Each flow is offered once every eighteen seconds for fifteen minutes per phase.
Requests use the trusted TLS roots and the public OPAQUE/OAuth APIs. The only
database read is the newly registered fixture user's development mailbox.
"""
import base64
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import runpy
import secrets
import socket
import ssl
import subprocess
import tempfile
import time
from urllib.parse import parse_qs, urlencode, urlsplit

common = runpy.run_path(str(Path(__file__).resolve().parents[1] / "verify-runtime.py"))
run, require = common["run"], common["require"]
ISSUER = "https://api.localhost:8443"
FRONTEND = "http://localhost:8080"
CALLBACK = "https://client.example.test/callback"


def measure(kube, core, edge, binary, record):
    """Provision one test-owned principal and measure its existing session and OAuth grants."""
    with ExitStack() as stack:
        cas = [run(kube + ["exec", "deploy/" + prefix + "-vault", "-c", "vault", "--", "bao",
                           "read", "-field=certificate", "pki-root/cert/ca"]) for prefix in sorted({core, edge})]
        tls = ssl.create_default_context(cadata="\n".join(cas))
        ca = Path(stack.enter_context(tempfile.TemporaryDirectory())) / "ca.pem"
        ca.write_text("\n".join(cas))
        def forward(target):
            owned = common["PortForward"](kube, target)
            stack.callback(owned.close)
            return owned.port
        app_port, edge_port = forward("svc/permesi"), forward("svc/permesi-genesis")
        # Open a distinct forward to each serving core Pod. Round-robin assignment
        # tests both replicas and avoids pinning every request to one service tunnel.
        deploy = json.loads(run(kube + ["get", "deploy", "permesi", "-o", "json"]))
        selector = ",".join(k + "=" + v for k, v in deploy["spec"]["selector"]["matchLabels"].items())
        live = json.loads(run(kube + ["get", "pods", "-l", selector, "-o", "json"]))["items"]
        ports = [forward("pod/" + p["metadata"]["name"]) for p in live if "deletionTimestamp" not in p["metadata"]]
        require(len(ports) >= 2, "capacity trial addresses at least two core replicas")
        index = 0
        def request(path, method="GET", *, data=None, form=None, headers=None, edge_request=False, expect=(200,)):
            nonlocal index
            host = "genesis.localhost" if edge_request else "api.localhost"
            port = edge_port if edge_request else ports[index % len(ports)]
            index += 1
            hdr = {"Host": host + (":9443" if edge_request else ":8443"), **(headers or {})}
            if form is not None:
                body = urlencode(form)
                hdr["Content-Type"] = "application/x-www-form-urlencoded"
            elif data is not None:
                body = json.dumps(data)
                hdr["Content-Type"] = "application/json"
            else:
                body = None
            with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                with tls.wrap_socket(raw, server_hostname=host) as stream:
                    conn = http.client.HTTPConnection(host, timeout=5)
                    conn.sock = stream
                    conn.request(method, path, body, hdr)
                    res = conn.getresponse()
                    body = res.read()
                    response_headers = res.headers
                    if res.status not in expect:
                        raise RuntimeError(f"{method} {path.split('?')[0]} returned {res.status}")
                    return body, response_headers
        def api(path, *args, **kwargs):
            body, _ = request(path, *args, **kwargs)
            return json.loads(body) if body else {}
        def admission():
            return api("/token?client_id=00000000-0000-0000-0000-000000000000", edge_request=True,
                       headers={"Origin": FRONTEND})["token"]
        log = run([binary, str(ca)], env={**os.environ, "QS_API_PORT": str(app_port), "QS_GENESIS_PORT": str(edge_port)})
        email = re.search(r"pending-account email=(qs-[a-f0-9]+@example\.test)", log).group(1)
        link = run(kube + ["exec", core + "-postgresql-0", "-c", "postgresql", "--", "psql", "-X", "-U", "postgres",
                           "-d", "permesi", "-tAc", "SELECT payload_json->>'verify_url' FROM email_outbox WHERE to_email='" + email + "'"])
        verification = parse_qs(urlsplit(link).fragment)["token"][0]
        auth = {"X-Permesi-Zero-Token": admission(), "Origin": FRONTEND}
        api("/v1/auth/verify-email", "POST", data={"token": verification}, headers=auth, expect=(204,))
        with subprocess.Popen([binary, "--login-proof", email], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              text=True) as proof:
            try:
                blinded = proof.stdout.readline().strip()
                exchange = api("/v1/auth/opaque/login/start", "POST", headers=auth, data={"email": email, "credential_request": blinded})
                result, _ = proof.communicate(input=json.dumps(exchange) + "\n", timeout=10)
            finally:
                if proof.poll() is None:
                    proof.kill()
            require(proof.returncode == 0, "legitimate OPAQUE client completed login proof")
        _, response = request("/v1/auth/opaque/login/finish", "POST", headers=auth, expect=(204,),
                              data={"email": email, "login_id": exchange["login_id"], "credential_finalization": result.strip()})
        cookie = next(c.split(";")[0] for c in response.get_all("Set-Cookie") if c.startswith("permesi_session="))
        browser = {"Cookie": cookie, "Origin": FRONTEND}
        def session():
            if api("/v1/auth/session", headers=browser)["session_kind"] != "full":
                raise RuntimeError("session is not full")
        session()
        org = api("/v1/orgs", "POST", data={"name": "Capacity trial", "slug": "capacity-" + secrets.token_hex(4)},
                  headers=browser, expect=(201,))
        path = "/v1/orgs/" + org["slug"] + "/projects"
        project = api(path, "POST", data={"name": "Test", "slug": "test"}, headers=browser, expect=(201,))
        path += "/" + project["slug"] + "/envs"
        env = api(path, "POST", data={"name": "Development", "slug": "dev", "tier": "non_production"},
                  headers=browser, expect=(201,))
        path += "/" + env["slug"] + "/apps"
        app = api(path, "POST", data={"name": "Capacity"}, headers=browser, expect=(201,))
        path += "/" + app["id"] + "/oauth/clients"
        client = api(path, "POST", data={"name": "Capacity", "client_type": "public"}, headers=browser, expect=(201,))["client_id"]
        path += "/" + client
        api(path + "/redirect-uris", "PUT", data={"redirect_uris": [CALLBACK]}, headers=browser)
        api(path + "/scopes", "PUT", data={"scopes": ["openid", "offline_access"]}, headers=browser)
        def code():
            verifier = secrets.token_urlsafe(40)
            state = secrets.token_urlsafe(32)
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            query = urlencode(dict(client_id=client, response_type="code", redirect_uri=CALLBACK, scope="openid offline_access", prompt="consent",
                                   code_challenge=challenge, code_challenge_method="S256", state=state,
                                   nonce=secrets.token_urlsafe(32), organization_id=org["id"]))
            page, hdr = request("/authorize?" + query, headers={"Cookie": cookie}, expect=(200, 302, 303))
            if not hdr.get("Location"):
                fields = {k.decode(): v.decode() for k, v in re.findall(rb'<input type="hidden" name="(request_id|csrf)" value="([^"]+)">', page)}
                if set(fields) != {"request_id", "csrf"}:
                    raise RuntimeError("authorization did not present consent")
                auxiliary = hdr.get("Set-Cookie").split(";")[0]
                _, hdr = request("/authorize/consent", "POST", form=dict(fields, decision="allow"),
                                 headers={"Origin": ISSUER, "Cookie": cookie + "; " + auxiliary}, expect=(302, 303))
            redirect = urlsplit(hdr["Location"])
            params = parse_qs(redirect.query)
            if hdr["Location"].split("?")[0] != CALLBACK or params.get("state") != [state] or params.get("iss") != [ISSUER]:
                raise RuntimeError("authorization callback identity mismatch")
            if "code" not in params:
                raise RuntimeError("authorization grant was denied")
            return api("/token", "POST", form=dict(grant_type="authorization_code", code=params["code"][0],
                       client_id=client, code_verifier=verifier, redirect_uri=CALLBACK))
        first = code()
        renewal = first["refresh_token"]
        access = first["access_token"]
        def refresh():
            nonlocal renewal, access
            result = api("/token", "POST", form=dict(grant_type="refresh_token", client_id=client, refresh_token=renewal))
            renewal = result["refresh_token"]
            access = result["access_token"]
        def authorize():
            nonlocal access
            access = code()["access_token"]
        def userinfo():
            if not api("/userinfo", headers={"Authorization": "Bearer " + access}).get("sub"):
                raise RuntimeError("UserInfo subject missing")
        flows = dict(session=session, authorization_code=authorize, refresh=refresh, userinfo=userinfo)
        for call in flows.values():
            call()
        def phase():
            start = time.monotonic()
            # Authorization and explicit consent both consume the default 100-per-600s
            # authorization budget for one source. Leave room for setup and
            # measure successful legitimate traffic with all production limits on.
            duration, interval = 900, 18
            def sample(call):
                latencies, failures = [], Counter()
                for offset in range(0, duration, interval):
                    due = start + offset
                    time.sleep(max(0, due - time.monotonic()))
                    if time.monotonic() - due >= interval:
                        failures["missed_deadline"] += 1
                        continue
                    try:
                        call()
                        latencies.append((time.monotonic() - due) * 1000)
                    except (OSError, RuntimeError, ValueError, KeyError, http.client.HTTPException) as error:
                        status = re.fullmatch(r"(GET|POST) (/[a-z/]+) returned ([0-9]{3})", str(error))
                        reason = status.group(0) if status else type(error).__name__
                        failures[reason] += 1
                offered = duration // interval
                return dict(offered=offered, successes=len(latencies), success_rate=len(latencies) / offered,
                            throughput=len(latencies) / duration, failures=sum(failures.values()), failure_reasons=dict(failures),
                            p95_ms=sorted(latencies)[math.ceil(.95 * len(latencies)) - 1] if latencies else None)
            with ThreadPoolExecutor(max_workers=len(flows)) as pool:
                jobs = {key: pool.submit(sample, call) for key, call in flows.items()}
                results = {key: job.result() for key, job in jobs.items()}
            time.sleep(max(0, start + duration - time.monotonic()))
            return results
        print("Capacity baseline started", flush=True)
        baseline = phase()
        run(kube + ["scale", "deploy/permesi-genesis", "--replicas=0"])
        try:
            run(kube + ["wait", "--for=delete", "pod", "-l", "app.kubernetes.io/name=genesis", "--timeout=60s"])
            print("Capacity Genesis-offline phase started", flush=True)
            fault = phase()
        finally:
            run(kube + ["scale", "deploy/permesi-genesis", "--replicas=2"])
            run(kube + ["rollout", "status", "deploy/permesi-genesis", "--timeout=180s"])
        print("CAPACITY " + json.dumps({"identity": record, "baseline": baseline, "genesis_offline": fault}), flush=True)
        for key in flows:
            b, f = baseline[key], fault[key]
            require(b["success_rate"] >= .99 and f["success_rate"] >= .99 and f["throughput"] >= .95 * b["throughput"]
                    and f["p95_ms"] <= 2 * b["p95_ms"], f"{key} meets the per-flow containment gates")
