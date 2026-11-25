"""Pause both disposable shared dependencies and verify local liveness, readiness and recovery."""
from contextlib import ExitStack
import http.client
import json
from pathlib import Path
import runpy
import socket
import ssl
import time

helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "verify-runtime.py"))
run, require = helpers["run"], helpers["require"]


def trial(kube, prefix):
    # Each in-container watchdog resumes its own processes after a bounded interval,
    # including if the client disconnects. Existing ephemeral key material survives.
    tls = ssl.create_default_context(cadata=run(kube + ["exec", "deploy/" + prefix + "-openbao", "-c", "openbao",
        "--", "bao", "read", "-field=certificate", "pki-root/cert/ca"]))
    with ExitStack() as stack:
        endpoints = []
        for name, host in [("permesi", "api.localhost"), ("permesi-genesis", "genesis.localhost")]:
            dep = json.loads(run(kube + ["get", "deploy", name, "-o", "json"]))
            selector = ",".join(k + "=" + v for k, v in dep["spec"]["selector"]["matchLabels"].items())
            for pod in json.loads(run(kube + ["get", "pods", "-l", selector, "-o", "json"]))["items"]:
                if "deletionTimestamp" not in pod["metadata"]:
                    port = helpers["PortForward"](kube, "pod/" + pod["metadata"]["name"])
                    stack.callback(port.close)
                    endpoints.append((host, port.port))
        require(len(endpoints) == 4, "shared outage starts with two serving replicas per backend")
        def status(endpoint, path):
            host, port = endpoint
            conn = http.client.HTTPConnection(host, timeout=3)
            with socket.create_connection(("127.0.0.1", port), timeout=3) as raw:
                with tls.wrap_socket(raw, server_hostname=host) as stream:
                    conn.sock = stream
                    conn.request("GET", path)
                    response = conn.getresponse()
                    response.read()
                    return response.status
        pause = runpy.run_path(str(Path(__file__).with_name("kind-pause.py")))["paused"]
        selector = json.loads(run(kube + ["get", "deploy", prefix + "-openbao", "-o", "json"]))["spec"]["selector"]["matchLabels"]
        pods = json.loads(run(kube + ["get", "pods", "-l", ",".join(k + "=" + v for k, v in selector.items()), "-o", "json"]))
        openbao, = [p["metadata"]["name"] for p in pods["items"] if "deletionTimestamp" not in p["metadata"]]
        with pause(kube, prefix + "-postgresql-0", "postgresql", 24), pause(kube, openbao, "openbao", 22):
            end = time.monotonic() + 16
            while time.monotonic() < end:
                if all(status(e, "/ready") == 503 for e in endpoints):
                    break
                time.sleep(.5)
            require(all(status(e, "/ready") == 503 and status(e, "/live") == 200 for e in endpoints),
                    "all replicas leave readiness while process liveness survives the complete shared outage")
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if all(status(e, "/ready") == 200 for e in endpoints):
                break
            time.sleep(1)
        require(all(status(e, "/ready") == 200 for e in endpoints), "all replicas recovered after shared dependencies resumed")
