#!/usr/bin/env python3
"""Qualify endpoint, Job-collection and OIDC contracts with real PostgreSQL/Vault.

Owns one absent qv-config-* namespace and its helper release. Uses the actual
installer/verifier; restores faulted state and removes only owned resources.
Captured child diagnostics and Vault responses are never printed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

QUICKSTART = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    """Capture private child output; expose only a sanitized failure."""
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed (exit {result.returncode}); diagnostics withheld")
    return result.stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)
    print("PASS: " + message, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--release", default="config")
    parser.add_argument("--app-source", required=True)
    args = parser.parse_args()
    require(args.namespace.startswith("qv-config-"), "configuration namespace is explicitly disposable")
    kubectl = ["kubectl", "--context", args.context, "-n", args.namespace]
    require(not run(kubectl + ["get", "namespace", args.namespace, "--ignore-not-found", "-o", "name"]),
            "configuration namespace does not already exist")
    helper = args.release + "-quickstart"
    vault = args.release + "-vault"
    root = kubectl + ["exec", "-i", "deploy/" + vault, "-c", "vault", "--", "vault"]
    verify = ["bash", str(QUICKSTART / "verify.sh"), "--context", args.context,
              "--namespace", args.namespace, "--release", args.release, "--deps-only"]
    with tempfile.TemporaryDirectory(prefix="quickstart-config-") as directory:
        values_path = Path(directory) / "values.json"
        values = {"postgresql": {"service": {"name": args.release + "-db", "port": 15432}},
                  "vault": {"service": {"name": vault, "port": 18200}},
                  "bootstrap": {"oidcSigning": {"enabled": False}}}
        install = ["bash", str(QUICKSTART / "install.sh"), "--context", args.context,
                   "--namespace", args.namespace, "--release", args.release,
                   "--acknowledge-development", "--deps-only", "--app-source", args.app_source,
                   "--quickstart-values", str(values_path)]
        run(kubectl + ["create", "namespace", args.namespace])
        try:
            run(kubectl + ["label", "namespace", args.namespace, "pod-security.kubernetes.io/enforce=restricted"])
            values_path.write_text(json.dumps(values))
            run(install)
            run(verify)
            missing = subprocess.run(root + ["read", "transit/permesi/keys/oidc-signing"],
                                     capture_output=True, text=True)
            require(missing.returncode != 0 and "No value found" in missing.stderr + missing.stdout,
                    "custom endpoint installation verifies with OIDC disabled and no RSA key")
            seed = run(root + ["kv", "get", "-mount=secret/permesi", "-field=opaque_server_seed", "config"])
            seed_fingerprint = hashlib.sha256(seed.encode()).digest()
            del seed

            jobs = json.loads(run(kubectl + ["get", "jobs", "-l",
                f"app.kubernetes.io/instance={helper},app.kubernetes.io/component=bootstrap", "-o", "json"]))
            require(bool(jobs["items"]), "a real successful bootstrap Job exists before collection")
            for job in jobs["items"]:
                require(job.get("status", {}).get("succeeded") == 1, "only completed bootstrap Jobs are collected")
                run(kubectl + ["delete", "job", job["metadata"]["name"], "--wait=true"])
            run(verify)
            require(True, "collected bootstrap Job still permits full durable dependency verification")

            path = "bootstrap/manager-rotation/permesi"
            marker = json.loads(run(root + ["kv", "get", "-format=json", "-mount=secret/permesi", path]))["data"]["data"]
            try:
                run(root + ["kv", "put", "-mount=secret/permesi", path, "-"],
                    input=json.dumps({**marker, "state": "pending"}))
                failed = subprocess.run(verify, capture_output=True, text=True)
                require(failed.returncode != 0 and
                        "FAIL: database/config/permesi initial manager rotation completed" in failed.stdout,
                        "missing Job does not hide incomplete durable bootstrap state")
            finally:
                run(root + ["kv", "put", "-mount=secret/permesi", path, "-"], input=json.dumps(marker))

            # A failed upgrade can leave healthy prior state after its failed Job
            # is collected. The Helm release failure must remain authoritative.
            values["bootstrap"]["pki"] = {"maxTtl": "invalid"}
            values_path.write_text(json.dumps(values))
            rejected = subprocess.run(install, capture_output=True, text=True)
            require(rejected.returncode != 0, "real bootstrap failure makes the helper upgrade fail")
            release = json.loads(run(["helm", "--kube-context", args.context, "-n", args.namespace,
                                      "status", helper, "-o", "json"]))
            require(release["info"]["status"] == "failed", "failed upgrade remains recorded by Helm")
            run(kubectl + ["delete", "jobs", "-l", f"app.kubernetes.io/instance={helper},app.kubernetes.io/component=bootstrap"])
            rejected = subprocess.run(verify, capture_output=True, text=True)
            require(rejected.returncode != 0 and "FAIL: helper Helm release deployed" in rejected.stdout,
                    "collection cannot hide a failed Helm release behind healthy prior state")
            del values["bootstrap"]["pki"]
            values_path.write_text(json.dumps(values))
            run(install)
            run(verify)

            job_name = args.release + "-expected-failure"
            lock = json.loads((QUICKSTART / "lock.json").read_text())["images"]["vault"]
            image = lock["repository"] + "@" + lock["digest"]
            failed_job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {
                "name": job_name, "labels": {"app.kubernetes.io/instance": helper,
                "app.kubernetes.io/component": "bootstrap"}}, "spec": {"backoffLimit": 0,
                "template": {"spec": {"automountServiceAccountToken": False,
                "restartPolicy": "Never", "securityContext": {"runAsNonRoot": True,
                "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{"name": "expected-failure", "image": image,
                    "command": ["sh", "-c", "exit 1"], "securityContext": {
                    "allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                    "capabilities": {"drop": ["ALL"]}}}]}}}}
            run(kubectl + ["apply", "-f", "-"], input=json.dumps(failed_job))
            try:
                run(kubectl + ["wait", "--for=condition=Failed", "job/" + job_name, "--timeout=90s"])
                failed = subprocess.run(verify, capture_output=True, text=True)
                require(failed.returncode != 0 and "FAIL: latest bootstrap Job succeeded" in failed.stdout,
                        "retained failed bootstrap Job rejects an otherwise healthy installation")
            finally:
                run(kubectl + ["delete", "job", job_name, "--wait=true"])

            values["bootstrap"]["oidcSigning"]["enabled"] = True
            values_path.write_text(json.dumps(values))
            run(install)
            run(verify)
            key_type = run(root + ["read", "-field=type", "transit/permesi/keys/oidc-signing"])
            require(key_type == "rsa-2048", "enabling OIDC provisions a real signing key and allowed signing")
            values["bootstrap"]["oidcSigning"]["enabled"] = False
            values_path.write_text(json.dumps(values))
            run(install)
            run(verify)
            require(run(root + ["read", "-field=type", "transit/permesi/keys/oidc-signing"]) == key_type,
                    "disabling OIDC preserves the existing key while requiring actual signing denial")
            after = run(root + ["kv", "get", "-mount=secret/permesi", "-field=opaque_server_seed", "config"])
            require(hashlib.sha256(after.encode()).digest() == seed_fingerprint,
                    "configuration changes preserve existing OPAQUE identity")
        finally:
            run(["helm", "--kube-context", args.context, "-n", args.namespace,
                 "uninstall", helper, "--ignore-not-found"])
            run(kubectl + ["delete", "namespace", args.namespace, "--ignore-not-found", "--wait=true"])


if __name__ == "__main__":
    main()
