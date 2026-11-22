"""Pause both disposable shared dependencies and verify local liveness, readiness and recovery."""
from contextlib import ExitStack
import http.client
import json
from pathlib import Path
import runpy
import socket
import ssl
import subprocess
import time

helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "verify-runtime.py"))
run, require = helpers["run"], helpers["require"]


def trial(kube, prefix):
    # Each in-container watchdog resumes its own processes after a bounded interval,
    # including if the client disconnects. Existing ephemeral key material survives.
    tls = ssl.create_default_context(cadata=run(kube + ["exec", "deploy/" + prefix + "-vault", "-c", "vault",
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
        def pause(target, container, selection):
            script = 'set -eu; pids=$(' + selection + '); test -n "$pids"; resume() { kill -CONT $pids 2>/dev/null || :; }; trap resume EXIT HUP INT TERM; kill -STOP $pids; echo paused; sleep 20'
            return subprocess.Popen(kube + ["exec", target, "-c", container, "--", "sh", "-c", script],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        jobs = [pause(prefix + "-postgresql-0", "postgresql", "pgrep -x postgres"),
                pause("deploy/" + prefix + "-vault", "vault", "pidof bao || pidof vault")]
        try:
            require(all(j.stdout.readline().strip() == "paused" for j in jobs), "both dependency watchdogs started")
            end = time.monotonic() + 16
            while time.monotonic() < end:
                if all(status(e, "/ready") == 503 for e in endpoints):
                    break
                time.sleep(.5)
            require(all(status(e, "/ready") == 503 and status(e, "/live") == 200 for e in endpoints),
                    "all replicas leave readiness while process liveness survives the complete shared outage")
        finally:
            for job in jobs:
                job.wait(timeout=30)
                job.stdout.close()
        require(all(job.returncode == 0 for job in jobs), "both dependency watchdogs resumed their processes")
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if all(status(e, "/ready") == 200 for e in endpoints):
                break
            time.sleep(1)
        require(all(status(e, "/ready") == 200 for e in endpoints), "all replicas recovered after shared dependencies resumed")
