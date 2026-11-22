"""Set up independent edge and core dependency pairs for packaged qualification."""
import copy
import json
from pathlib import Path
import runpy

helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "verify-runtime.py"))
run, require = helpers["run"], helpers["require"]


def install_dependencies(kube, helm, fixture, values, directory, namespace):
    """Install separately limited PostgreSQL/OpenBao pairs and bind only their own workload."""
    quickstart = values.pop("quickstart")
    prefixes = {"permesi": "core-quickstart", "genesis": "edge-quickstart"}
    for service, prefix in prefixes.items():
        helper = copy.deepcopy(quickstart)
        helper.pop("enabled")
        helper["fullnameOverride"] = prefix
        peer = "permesi" if service == "genesis" else "genesis"
        helper["bootstrap"]["kubernetesRoles"][peer]["serviceAccount"] = "unused-" + peer
        path = directory / (prefix + ".json")
        path.write_text(json.dumps(helper))
        run(helm + ["install", prefix, str(fixture / "scripts/quickstart/chart"), "-f", str(path),
                    "--wait", "--wait-for-jobs", "--timeout", "300s"])
        v = values[service]
        v["database"]["dsn"]["value"] = v["database"]["dsn"]["value"].replace("permesi-quickstart-postgresql",
                                                                             prefix + "-postgresql")
        v["vault"]["agent"]["address"] = f"http://{prefix}-vault.{namespace}.svc:8200"
    values["quickstart"] = {"enabled": False}
    apply = kube + ["apply", "-f", "-"]
    edge = kube + ["exec", "-i", "deploy/edge-quickstart-vault", "-c", "vault", "--", "bao"]
    run(edge + ["policy", "write", "admission-reader", "-"],
        input='path "transit/genesis/keys/genesis-signing" { capabilities = ["read"] }\n')
    run(edge + ["write", "auth/kubernetes/role/admission-reader", "bound_service_account_names=admission-reader",
                "bound_service_account_namespaces=" + namespace, "audience=admission-reader",
                "token_policies=admission-reader", "token_no_default_policy=true", "token_ttl=10m"])
    metadata = {"name": "admission-reader", "namespace": namespace}
    def apply_object(kind, **fields):
        run(apply, input=json.dumps(dict(apiVersion="v1", kind=kind, metadata=metadata, **fields)))
    apply_object("ServiceAccount", automountServiceAccountToken=False)
    config = f"""
vault {{ address = "http://edge-quickstart-vault.{namespace}.svc:8200" }}
auto_auth {{
  method "kubernetes" {{
    mount_path = "auth/kubernetes"
    config = {{ role = "admission-reader", token_path = "/identity/token" }}
  }}
}}
listener "unix" {{ address = "/run/reader/agent.sock" tls_disable = true socket_mode = "0600" }}
api_proxy {{ use_auto_auth_token = true }}
"""
    apply_object("ConfigMap", data={"agent.hcl": config})
    image = quickstart["vault"]["image"]
    apply_object("Pod", spec={"serviceAccountName": metadata["name"], "automountServiceAccountToken": False,
        "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001, "fsGroup": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "volumes": [{"name": "config", "configMap": {"name": metadata["name"]}},
                    {"name": "run", "emptyDir": {"medium": "Memory"}},
                    {"name": "identity", "projected": {"sources": [{"serviceAccountToken": {
                        "path": "token", "audience": "admission-reader", "expirationSeconds": 600}}]}}],
        "containers": [{"name": "agent", "image": image["repository"] + "@" + image["digest"],
            "command": ["/usr/bin/bao", "agent", "-config=/config/agent.hcl"],
            "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
            "volumeMounts": [{"name": name, "mountPath": path, "readOnly": name != "run"}
                             for name, path in [("config", "/config"), ("identity", "/identity"), ("run", "/run/reader")]],
            "readinessProbe": {"exec": {"command": ["bao", "read", "-address=unix:///run/reader/agent.sock",
                "-field=type", "transit/genesis/keys/genesis-signing"]}, "periodSeconds": 3}}]})
    run(kube + ["wait", "--for=condition=Ready", "pod/admission-reader", "--timeout=120s"])
    return kube + ["exec", "admission-reader", "--", "bao", "read", "-address=unix:///run/reader/agent.sock"]


def verify(kube, lock, client, namespace):
    """Check every running identity and complete real signup through independent TLS roots."""
    from contextlib import ExitStack
    import os
    import tempfile
    import time
    with ExitStack() as stack:
        roots = []
        ports = {}
        for service, prefix in [("permesi", "core"), ("genesis", "edge"), ("web", None)]:
            name = "permesi" if service == "permesi" else "permesi-" + service
            deployment = json.loads(run(kube + ["get", "deployment", name, "-o", "json"]))
            selector = ",".join(k + "=" + v for k, v in deployment["spec"]["selector"]["matchLabels"].items())
            pods = json.loads(run(kube + ["get", "pods", "-l", selector, "-o", "json"]))["items"]
            require(len(pods) == deployment["status"]["readyReplicas"] == 2, f"two ready isolated-profile {service} replicas")
            image = lock["images"][service]
            for pod in pods:
                actual = next(c for c in pod["status"]["containerStatuses"] if c["name"] == service)
                require(actual["imageID"].split("@")[-1] == image["digest"], f"{service} running manifest matches record")
                if prefix:
                    version = run(kube + ["exec", pod["metadata"]["name"], "-c", service, "--", "/app/" + service, "--version"])
                    require(lock["appRevision"] in version, f"{service} binary matches application revision")
            if prefix:
                roots.append(run(kube + ["exec", "deploy/" + prefix + "-quickstart-vault", "-c", "vault", "--",
                                         "bao", "read", "-field=certificate", "pki-root/cert/ca"]))
                forward = helpers["PortForward"](kube, "svc/" + name)
                stack.callback(forward.close)
                ports[service] = str(forward.port)
        require(roots[0] != roots[1], "core and edge have independently generated TLS roots")
        ca = Path(stack.enter_context(tempfile.TemporaryDirectory())) / "roots.pem"
        ca.write_text("\n".join(roots))
        port = ports["permesi"]
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status = run(["curl", "--noproxy", "*", "--silent", "--show-error", "--fail", "--max-time", "5",
                          "--cacert", str(ca), "--resolve", f"api.localhost:{port}:127.0.0.1",
                          f"https://api.localhost:{port}/health"])
            if json.loads(status)["status"] == "ok":
                break
            time.sleep(1)
        else:
            raise RuntimeError("core admission authority never became healthy")
        out = run([client, str(ca)], env={**os.environ, "QS_API_PORT": ports["permesi"], "QS_GENESIS_PORT": ports["genesis"]})
        require("signup/finish 201" in out, "completed OPAQUE signup across the isolated dependencies")
