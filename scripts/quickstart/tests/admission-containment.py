#!/usr/bin/env python3
"""Verify expiry during a Genesis outage and time withdrawal across individual core pods.

Invoked only inside the owned packaged candidate test, after reinstall checks.
The operator advances the authority using KV CAS. Tokens stay in process memory.
"""
import base64
from contextlib import ExitStack
from datetime import datetime
import http.client
import json
from pathlib import Path
import runpy
import socket
import ssl
import time
import uuid

helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "verify-runtime.py"))
PortForward, run, require = (helpers[k] for k in ("PortForward", "run", "require"))


def trial(kube, core="permesi-quickstart", edge="permesi-quickstart", reader=None, rollback=None):
    def operator_for(prefix):
        return kube + ["exec", "-i", "deploy/" + prefix + "-vault", "-c", "vault", "--", "bao"]
    operator = operator_for(core)
    signer = operator_for(edge)
    reader = reader or signer + ["read"]
    roots = [run(operator_for(prefix) + ["read", "-field=certificate", "pki-root/cert/ca"]) for prefix in sorted({core, edge})]
    tls = ssl.create_default_context(cadata="\n".join(roots))
    deployment = json.loads(run(kube + ["get", "deploy", "permesi", "-o", "json"]))
    labels = deployment["spec"]["selector"]["matchLabels"]
    selector = ",".join(f"{key}={value}" for key, value in labels.items())
    def replicas():
        return sorted(p["metadata"]["name"] for p in json.loads(run(kube + ["get", "pods", "-l", selector,
            "-o", "json"]))["items"] if "deletionTimestamp" not in p["metadata"] and any(c["type"] == "Ready" and c["status"] == "True"
            for c in p["status"].get("conditions", [])))
    nodes = replicas()
    require(len(nodes) == deployment["spec"]["replicas"] >= 2, "every core replica is ready for withdrawal measurement")
    def request(port, host, path, token=None):
        connection = http.client.HTTPConnection(host, timeout=5)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
            with tls.wrap_socket(raw, server_hostname=host) as stream:
                connection.sock = stream
                headers = {"Origin": "http://localhost:8080"}
                body = None
                if token:
                    # Standard compressed Ristretto255 generator, a valid blinded group element.
                    point = bytes.fromhex("e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76")
                    body = json.dumps({"email": f"trial-{uuid.uuid4().hex}@example.test",
                                       "registration_request": base64.b64encode(point).decode()})
                    headers.update({"Content-Type": "application/json", "X-Permesi-Zero-Token": token})
                connection.request("POST" if body else "GET", path, body, headers)
                response = connection.getresponse()
                return response.status, response.read()
    def mint():
        fwd = PortForward(kube, "svc/permesi-genesis")
        try:
            status, data = request(fwd.port, "genesis.localhost", "/token?client_id=00000000-0000-0000-0000-000000000000")
        finally:
            fwd.close()
        require(status == 200, "Genesis issued a legitimate admission token")
        token = json.loads(data)["token"]
        body = token.split(".")[2]
        claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))[:-64])
        issued, expiry = (datetime.fromisoformat(claims[key].replace("Z", "+00:00")).timestamp()
                          for key in ("iat", "exp"))
        require(expiry - issued == 120, "issued admission lifetime is exactly 120 seconds")
        return token, expiry

    with ExitStack() as stack:
        forwards = []
        for node in nodes:
            forward = PortForward(kube, "pod/" + node)
            stack.callback(forward.close)
            forwards.append(forward)
        def signup(port, token):
            return request(port, "api.localhost", "/v1/auth/opaque/signup/start", token)
        def rejected(result):
            status, body = result
            return status == 400 and b"Invalid token" in body
        token, expiry = mint()
        run(kube + ["scale", "deploy/permesi-genesis", "--replicas=0"])
        try:
            run(kube + ["wait", "--for=delete", "pod", "-l", "app.kubernetes.io/name=genesis", "--timeout=60s"])
            def audit_count(prefix, path):
                awk = '/"type":"request"/ && index($0, needle) { n++ } END { print n+0 }'
                return int(run(kube + ["exec", "deploy/" + prefix + "-vault", "-c", "vault", "--", "awk",
                    "-v", 'needle="path":"' + path + '"', awk, "/audit/entry-audit.json"]))
            for attempt in range(3):
                reads = audit_count(core, "secret/permesi/data/admission-authority")
                signs = audit_count(edge, "transit/genesis/sign/genesis-signing")
                for forward in forwards:
                    require(signup(forward.port, token)[0] == 200, "same token starts OPAQUE signup with Genesis offline")
                require(signs == audit_count(edge, "transit/genesis/sign/genesis-signing"),
                        "no signing call occurred during offline admission-token reuse")
                if audit_count(core, "secret/permesi/data/admission-authority") == reads:
                    break
            else:
                raise RuntimeError("could not observe the requests without an authority fetch")
            require(True, "both serving replicas accepted the token with zero authority reads during the sampled requests")
            time.sleep(max(0, expiry - time.time() + 1))
            for forward in forwards:
                require(rejected(signup(forward.port, token)), "same expired token rejected while Genesis remains offline")
        finally:
            run(kube + ["scale", "deploy/permesi-genesis", "--replicas=2"])
            run(kube + ["rollout", "status", "deploy/permesi-genesis", "--timeout=180s"])
        token, expiry = mint()
        for forward in forwards:
            require(signup(forward.port, token)[0] == 200, "fresh token accepted on the serving replica before withdrawal")
        run(signer + ["write", "-force", "transit/genesis/keys/genesis-signing/rotate"])
        keys = json.loads(run(reader + ["-format=json", "transit/genesis/keys/genesis-signing"]))["data"]
        record = json.loads(run(operator + ["kv", "get", "-format=json", "-mount=secret/permesi", "admission-authority"]))["data"]
        require(record["data"]["minimum_version"] == 1 and keys["latest_version"] == 2,
                "withdrawal begins with the original floor and a staged second key")
        start = time.monotonic()
        run(operator + ["kv", "put", "-mount=secret/permesi", "-cas=" + str(record["metadata"]["version"]),
                        "admission-authority", "-"], input=json.dumps({"minimum_version": 2,
                        "keys": {"2": keys["keys"]["2"]["public_key"]}}))
        remaining = {node: fwd for node, fwd in zip(nodes, forwards)}
        while remaining and time.monotonic() - start < 60:
            for node, forward in list(remaining.items()):
                result = signup(forward.port, token)
                if rejected(result):
                    elapsed = time.monotonic() - start
                    require(elapsed <= 60 and time.time() < expiry, f"{node} rejected the unexpired token after {elapsed:.2f}s")
                    del remaining[node]
                elif result[0] != 200:
                    raise RuntimeError("unexpected status during key withdrawal: " + str(result[0]))
            if remaining:
                time.sleep(2)
        require(not remaining and nodes == replicas(), "every serving core replica observed withdrawal within 60 seconds")
        if rollback:
            rollback()
            for node in replicas():
                fresh = PortForward(kube, "pod/" + node)
                stack.callback(fresh.close)
                require(time.time() < expiry and rejected(signup(fresh.port, token)),
                        f"{node} rejected the same unexpired token after binary rollback")
