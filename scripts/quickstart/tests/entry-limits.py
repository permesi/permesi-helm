"""Measure receipt SQL, admission signatures and CPU for a bounded burst in an owned pod."""
import base64
from concurrent.futures import ThreadPoolExecutor
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


def measure(kube, pod, namespace, admin, edge):
    sql = kube + ["exec", edge + "-postgresql-0", "-c", "postgresql", "--", "psql", "-X",
                  "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-Atc"]
    run(sql + ["CREATE EXTENSION IF NOT EXISTS pg_stat_statements"])
    def counts():
        query = """SELECT coalesce(sum(calls) FILTER(WHERE query LIKE 'SELECT id, is_reserved FROM clients%'),0),
            coalesce(sum(calls) FILTER(WHERE query LIKE 'INSERT INTO tokens (client_id,%'),0)
            FROM pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname='genesis')"""
        return tuple(map(int, run(sql + [query]).split("|")))
    name = pod["metadata"]["name"]
    node = pod["spec"]["nodeName"]
    def cpu():
        data = json.loads(run(kube + ["get", "--raw", "/api/v1/nodes/" + node + "/proxy/stats/summary"]))
        target = next(p for p in data["pods"] if p["podRef"]["namespace"] == namespace and p["podRef"]["name"] == name)
        return next(c for c in target["containers"] if c["name"] == "genesis")["cpu"]["usageCoreNanoSeconds"]
    tls = ssl.create_default_context(cadata=run(admin + ["read", "-field=certificate", "pki-root/cert/ca"]))
    forward = helpers["PortForward"](kube, "pod/" + name)
    def mint(_):
        conn = http.client.HTTPConnection("genesis.localhost", timeout=5)
        with socket.create_connection(("127.0.0.1", forward.port), timeout=5) as raw:
            with tls.wrap_socket(raw, server_hostname="genesis.localhost") as stream:
                conn.sock = stream
                conn.request("GET", "/token?client_id=00000000-0000-0000-0000-000000000000")
                res = conn.getresponse()
                res.read()
                return res.status
    try:
        probe = base64.b64encode(b"genesis readiness v1").decode()
        digest = run(admin + ["write", "-field=hash", "sys/audit-hash/trial", "input=" + probe])
        def signatures():
            # Count only requests inside the service. Keep the default audit HMAC protection.
            awk = '/"type":"request"/ && /"path":"transit\\/genesis\\/sign\\/genesis-signing"/ && index($0, h)==0 { n++ } END { print n+0 }'
            return int(run(kube + ["exec", "deploy/" + edge + "-openbao", "-c", "openbao", "--",
                                   "awk", "-v", "h=" + digest, awk, "/audit/entry-audit.json"]))
        # Wait for kubelet to observe the new container before sampling.
        deadline = time.monotonic() + 45
        while True:
            try:
                cpu_before = cpu()
                break
            except (StopIteration, KeyError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("missing kubelet CPU observation")
                time.sleep(2)
        cpu_start = time.monotonic()
        before = counts()
        signed = signatures()
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=8) as pool:
            statuses = list(pool.map(mint, range(16)))
        elapsed = time.monotonic() - started
        accepted = statuses.count(200)
        require(accepted > 0 and statuses.count(429) > 0 and all(status in (200, 429) for status in statuses)
                and accepted <= 1 + int(elapsed), "configured one-request burst and one-per-second rate hold")
        after = counts()
        signatures_done = signatures() - signed
        require(tuple(a-b for a, b in zip(after, before)) == (accepted, accepted) and signatures_done == accepted,
                "each success produced one lookup, receipt and signature; all entry rejections added zero")
        deadline = time.monotonic() + 30
        cpu_after = cpu()
        while cpu_after == cpu_before and time.monotonic() < deadline:
            time.sleep(1)
            cpu_after = cpu()
        require(cpu_after > cpu_before, "kubelet observed CPU consumption across the burst interval")
        measured = dict(accepted=accepted, rejected=statuses.count(429),
              lookup_calls=after[0]-before[0], receipt_calls=after[1]-before[1], signatures=signatures_done,
              interval_seconds=elapsed, cpu_observation_seconds=time.monotonic()-cpu_start, sampled_cpu_ms=(cpu_after-cpu_before)/1e6)
        print("ENTRY " + json.dumps(measured), flush=True)
        # A test-owned maintenance transaction holds the first lookup so the rate
        # token can refill while the one in-flight slot is still occupied.
        time.sleep(1.1)
        before = counts()
        signed = signatures()
        psql = kube + ["exec", "-i", edge + "-postgresql-0", "-c", "postgresql", "--", "psql",
                       "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "genesis"]
        with subprocess.Popen(psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as lock:
            lock.stdin.write("BEGIN; SET LOCAL idle_in_transaction_session_timeout='8s'; "
                             "LOCK TABLE clients IN ACCESS EXCLUSIVE MODE; SELECT 'locked';\n")
            lock.stdin.flush()
            require(lock.stdout.readline().strip() == "locked", "fixture acquired the bounded maintenance lock")
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(mint, None)
                try:
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline:
                        if run(sql + ["SELECT count(*) FROM pg_stat_activity WHERE datname='genesis' "
                                      "AND wait_event_type='Lock' AND query LIKE 'SELECT id, is_reserved FROM clients%'"]) == "1":
                            break
                        time.sleep(.05)
                    else:
                        raise RuntimeError("could not observe the in-flight lookup")
                    time.sleep(1.1)
                    require(mint(None) == 429 and not pending.done(),
                            "one occupied in-flight slot sheds work even after the rate token refills")
                finally:
                    lock.stdin.write("ROLLBACK;\n")
                    lock.stdin.close()
                require(pending.result(timeout=5) == 200, "admitted work completed when the maintenance lock released")
        after = counts()
        require(tuple(a-b for a,b in zip(after, before)) == (1, 1) and signatures()-signed == 1,
                "the concurrency rejection produced zero additional lookups, receipts and signatures")
        measured["refilled_in_flight_rejections"] = 1
        return measured
    finally:
        forward.close()
