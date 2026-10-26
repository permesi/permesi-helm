#!/usr/bin/env python3
"""Qualify real Agent -> native Kubernetes -> AppRole -> Agent transitions.

Requires charts selecting supporting application images already available to the
cluster, an actual admission client and an absent qv-auth-* namespace. Private
certificates/credentials stay in memory and Kubernetes test Secrets; subprocess
responses are never printed. Only this invocation's namespace/releases are removed.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

QUICKSTART = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_runtime", QUICKSTART / "verify-runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed (exit {result.returncode}); diagnostics withheld")
    return result.stdout.strip()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)
    print("PASS: " + message, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--release", default="modes")
    parser.add_argument("--app-source", required=True)
    parser.add_argument("--charts-dir", type=Path, required=True)
    parser.add_argument("--admission-bin", required=True)
    args = parser.parse_args()
    require(args.namespace.startswith("qv-auth-"), "authentication namespace is explicitly disposable")
    k = ["kubectl", "--context", args.context, "-n", args.namespace]
    h = ["helm", "--kube-context", args.context, "-n", args.namespace]
    require(not run(k + ["get", "namespace", args.namespace, "--ignore-not-found", "-o", "name"]),
            "authentication namespace does not already exist")
    helper = args.release + "-quickstart"
    names = {"permesi": runtime.fullname(args.release, "permesi"),
             "genesis": runtime.fullname(args.release + "-genesis", "genesis")}
    releases = {"permesi": args.release, "genesis": args.release + "-genesis"}
    root = k + ["exec", "-i", "deploy/" + helper + "-vault", "-c", "vault", "--", "vault"]
    secrets = []
    originals = {}

    def kj(*arguments):
        return json.loads(run(k + list(arguments) + ["-o", "json"]))

    def pods(service):
        selector = kj("get", "deployment", names[service])["spec"]["selector"]["matchLabels"]
        labels = ",".join(f"{key}={value}" for key, value in selector.items())
        return [pod for pod in kj("get", "pods", "-l", labels)["items"]
                if not pod["metadata"].get("deletionTimestamp")]

    def upgrade(service, values):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as file:
            json.dump(values, file)
            file.flush()
            run(h + ["upgrade", releases[service], str(args.charts_dir / service),
                     "--reset-values", "-f", file.name, "--wait", "--timeout", "300s"])

    def secret(name, values):
        document = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name},
                    "type": "Opaque", "data": {
                        key: base64.b64encode(value.encode()).decode() for key, value in values.items()}}
        run(k + ["create", "-f", "-"], input=json.dumps(document))
        secrets.append(name)

    def https_and_admission(label, ca):
        forwards = {}
        try:
            for service, name in names.items():
                forwards[service] = runtime.PortForward(k, "svc/" + name)
                # curl retains hostname verification while resolving the owned loopback forward.
                host = "api.localhost" if service == "permesi" else "genesis.localhost"
                with tempfile.NamedTemporaryFile(mode="w") as file:
                    file.write(ca)
                    file.flush()
                    run(["curl", "--noproxy", "*", "-fsS", "--cacert", file.name,
                         "--resolve", f"{host}:{forwards[service].port}:127.0.0.1",
                         f"https://{host}:{forwards[service].port}/ready"])
            with tempfile.NamedTemporaryFile(mode="w") as file:
                file.write(ca)
                file.flush()
                run([args.admission_bin, file.name], env={**os.environ,
                    "QS_API_PORT": str(forwards["permesi"].port),
                    "QS_GENESIS_PORT": str(forwards["genesis"].port)})
            require(True, label + ": two services Ready over verified TLS and real admission/OPAQUE signup succeeds")
        finally:
            for forward in forwards.values():
                forward.close()

    run(k + ["create", "namespace", args.namespace])
    try:
        run(k + ["label", "namespace", args.namespace, "pod-security.kubernetes.io/enforce=restricted"])
        run(["bash", str(QUICKSTART / "install.sh"), "--context", args.context,
             "--namespace", args.namespace, "--release", args.release,
             "--acknowledge-development", "--app-source", args.app_source,
             "--charts-dir", str(args.charts_dir)])
        ca = run(root + ["read", "-field=certificate", "pki-root/cert/ca"]) + "\n"
        for service, release in releases.items():
            originals[service] = json.loads(run(h + ["get", "values", release, "--all", "-o", "json"]))
        https_and_admission("Agent", ca)

        native = {}
        for service, original in originals.items():
            name = names[service]
            dns = [name, f"{name}.{args.namespace}", f"{name}.{args.namespace}.svc",
                   f"{name}.{args.namespace}.svc.cluster.local",
                   "api.localhost" if service == "permesi" else "genesis.localhost"]
            certificate = json.loads(run(root + ["write", "-format=json", f"pki-int/issue/{service}-runtime",
                "common_name=" + dns[-2], "alt_names=" + ",".join(dns), "ttl=30m"]))["data"]
            bundle = "\n".join([certificate["private_key"], certificate["certificate"], *certificate["ca_chain"]])
            secret(name + "-qualification-tls", {"bundle.pem": bundle, "ca.pem": ca})
            del certificate, bundle
            values = json.loads(json.dumps(original))
            values["vault"]["agent"]["enabled"] = False
            values["vault"]["url"] = f"http://{helper}-vault.{args.namespace}.svc:8200"
            values["vault"]["authMethod"] = "kubernetes"
            values["vault"]["kubernetes"]["role"] = service
            values["tls"]["existingSecret"] = name + "-qualification-tls"
            if service == "permesi":
                values["admission"]["paserkCa"]["existingSecret"] = name + "-qualification-tls"
            upgrade(service, values)
            native[service] = values
            current = pods(service)
            require(len(current) == 2, service + ": native rollout has two active pods")
            for pod in current:
                require(not pod["spec"].get("initContainers") and
                        any("projected" in volume for volume in pod["spec"]["volumes"]),
                        service + ": native application auth uses projected JWT without an Agent")
        https_and_admission("Native Kubernetes", ca)

        # Invalid audience must fail before any database credential is issued.
        def leases():
            result = subprocess.run(root + ["list", "-format=json", "sys/leases/lookup/database/creds/permesi"],
                                    capture_output=True, text=True)
            require(result.returncode == 0, "read real permesi lease inventory")
            return set(json.loads(result.stdout))

        before = leases()
        specimen = json.loads(json.dumps(pods("permesi")[0]["spec"]))
        specimen.pop("nodeName", None)
        for volume in specimen["volumes"]:
            for projection in volume.get("projected", {}).get("sources", []):
                if "serviceAccountToken" in projection:
                    projection["serviceAccountToken"]["audience"] = "wrong-audience"
        bad_name = args.release + "-wrong-audience"
        run(k + ["create", "-f", "-"], input=json.dumps({"apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": bad_name}, "spec": specimen}))
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                pod = kj("get", "pod", bad_name)
                status = next(iter(pod.get("status", {}).get("containerStatuses", [])), {})
                if status.get("restartCount", 0) > 0:
                    require(not status.get("ready"), "wrong-audience native application fails closed")
                    require(leases() == before, "rejected native JWT creates no database lease")
                    break
                time.sleep(1)
            else:
                raise RuntimeError("wrong-audience native application did not reject its JWT")
        finally:
            run(k + ["delete", "pod", bad_name, "--wait=true"])

        # Revoking all tokens for one isolated service also revokes their DB leases.
        previous = {p["metadata"]["uid"]: next(s["restartCount"] for s in p["status"]["containerStatuses"]
                    if s["name"] == "permesi") for p in pods("permesi")}
        accessors = json.loads(run(root + ["list", "-format=json", "auth/token/accessors"]))
        revoked = 0
        for accessor in accessors:
            token = json.loads(run(root + ["token", "lookup", "-format=json", "-accessor", accessor]))["data"]
            if (token.get("meta") or {}).get("service_account_name") == names["permesi"]:
                run(root + ["token", "revoke", "-accessor", accessor])
                revoked += 1
        require(revoked >= 2, "revoked actual native service tokens by private accessor")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            current = pods("permesi")
            if len(current) == 2 and all(p["metadata"]["uid"] in previous and
                   any(s["name"] == "permesi" and s.get("ready") and
                       s["restartCount"] > previous[p["metadata"]["uid"]]
                       for s in p["status"].get("containerStatuses", [])) for p in current):
                require(all(next(s for s in p["status"]["containerStatuses"] if s["name"] == "permesi")
                            .get("lastState", {}).get("terminated", {}).get("exitCode", 0) != 0 for p in current),
                        "native token revocation causes a nonzero application exit before recovery")
                require(True, "native token revocation recovers through fail-closed container restart")
                break
            time.sleep(2)
        else:
            raise RuntimeError("native service did not recover from token revocation")
        https_and_admission("Native restart recovery", ca)

        run(root + ["auth", "enable", "approle"])
        for service, values in native.items():
            policies = "permesi,permesi-pki,permesi-oidc" if service == "permesi" else "genesis,genesis-pki"
            role = service + "-qualification"
            run(root + ["write", "auth/approle/role/" + role, "token_policies=" + policies,
                        "token_ttl=5m", "token_max_ttl=10m", "secret_id_ttl=1h", "secret_id_num_uses=0"])
            role_id = run(root + ["read", "-field=role_id", "auth/approle/role/" + role + "/role-id"])
            secret_id = run(root + ["write", "-f", "-field=secret_id", "auth/approle/role/" + role + "/secret-id"])
            credential_name = names[service] + "-qualification-approle"
            secret(credential_name, {"role_id": role_id, "secret_id": secret_id})
            del role_id, secret_id
            values["vault"]["authMethod"] = "approle"
            values["vault"]["kubernetes"]["role"] = ""
            for field in ("roleId", "secretId"):
                values["vault"][field]["existingSecret"] = credential_name
            upgrade(service, values)
        https_and_admission("Direct AppRole base URL", ca)

        for service, values in originals.items():
            upgrade(service, values)
        for name in secrets:
            run(k + ["delete", "secret", name])
        secrets.clear()
        run(["bash", str(QUICKSTART / "verify.sh"), "--context", args.context,
             "--namespace", args.namespace, "--release", args.release],
            env={**os.environ, "QS_ADMISSION_BIN": args.admission_bin})
        require(True, "restored Agent mode passes the common full-stack verifier")
    finally:
        for release in (args.release, args.release + "-genesis", args.release + "-web", helper):
            run(h + ["uninstall", release, "--ignore-not-found"])
        run(k + ["delete", "namespace", args.namespace, "--ignore-not-found", "--wait=true"])


if __name__ == "__main__":
    main()
