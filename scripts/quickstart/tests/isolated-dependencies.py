"""Set up independent edge and core dependency pairs for packaged qualification."""
import copy
import json
from pathlib import Path
import runpy
import subprocess

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
        v["openbao"]["agent"]["address"] = f"http://{prefix}-openbao.{namespace}.svc:8200"
    values["quickstart"] = {"enabled": False}
    apply = kube + ["apply", "-f", "-"]
    edge = kube + ["exec", "-i", "deploy/edge-quickstart-openbao", "-c", "openbao", "--", "bao"]
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
vault {{ address = "http://edge-quickstart-openbao.{namespace}.svc:8200" }}
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
    image = quickstart["openbao"]["image"]
    apply_object("Pod", spec={"serviceAccountName": metadata["name"], "automountServiceAccountToken": False,
        "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001, "fsGroup": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "volumes": [{"name": "config", "configMap": {"name": metadata["name"]}},
                    {"name": "run", "emptyDir": {"medium": "Memory", "sizeLimit": "1Mi"}},
                    {"name": "identity", "projected": {"defaultMode": 0o400, "sources": [{"serviceAccountToken": {
                        "path": "token", "audience": "admission-reader", "expirationSeconds": 600}}]}}],
        "containers": [{"name": "agent", "image": image["repository"] + "@" + image["digest"],
            "command": ["/usr/bin/bao", "agent", "-config=/config/agent.hcl"],
            "resources": {"requests": {"cpu": "20m", "memory": "64Mi"}, "limits": {"cpu": "100m", "memory": "128Mi"}},
            "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
            "volumeMounts": [{"name": name, "mountPath": path, "readOnly": name != "run"}
                             for name, path in [("config", "/config"), ("identity", "/identity"), ("run", "/run/reader")]],
            "readinessProbe": {"exec": {"command": ["bao", "read", "-address=unix:///run/reader/agent.sock",
                "-field=type", "transit/genesis/keys/genesis-signing"]}, "periodSeconds": 3}}]})
    run(kube + ["wait", "--for=condition=Ready", "pod/admission-reader", "--timeout=120s"])
    return kube + ["exec", "admission-reader", "--", "bao", "read", "-address=unix:///run/reader/agent.sock"]


SIGNING_KEY = "transit/genesis/keys/genesis-signing"


def _openbao(kube, side):
    return kube + ["exec", "-i", f"deploy/{side}-quickstart-openbao", "-c", "openbao", "--"]


def _login(kube, side, account, role, audience="openbao"):
    """Kubernetes-auth login of a real ServiceAccount token; returns the client token or ''."""
    jwt = run(kube + ["create", "token", account, "--audience", audience, "--duration", "10m"])
    result = subprocess.run(_openbao(kube, side) + ["bao", "write", "-field=token", "auth/kubernetes/login",
                                                    "role=" + role, "jwt=-"], input=jwt, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def _denied(command, token=None):
    """True only for an OpenBao permission denial; any other failure or a success is False."""
    result = subprocess.run(command, input=token, text=True, capture_output=True)
    return result.returncode != 0 and "permission denied" in result.stderr


def _as(kube, side, *operation):
    """OpenBao CLI on that side with the token read from stdin, never from argv."""
    return _openbao(kube, side) + ["sh", "-c", 'BAO_TOKEN="$(cat)" exec bao "$@"', "bao", *operation]


def _role_count(kube, side, username):
    literal = username.replace("'", "''")
    return run(kube + ["exec", f"{side}-quickstart-postgresql-0", "-c", "postgresql", "--", "psql", "-X", "-U", "postgres",
                       "-d", "postgres", "-tAc", f"SELECT count(*) FROM pg_roles WHERE rolname='{literal}'"])


def verify_isolation(kube):
    """Each side's identities and credentials are refused by the other side's dependencies.

    The isolated profile exists so that a compromise of the edge cannot reach the core
    and the reverse. Nothing here relies on network policy: every refusal below comes
    from OpenBao role bindings, separate token stores, separate database engines and
    the admission reader's single-path policy.
    """
    core_token = _login(kube, "core", "permesi", "permesi")
    edge_token = _login(kube, "edge", "permesi-genesis", "genesis")
    require(bool(core_token) and bool(edge_token), "each backend logs in to its own OpenBao with its own role")
    try:
        for side, account, role, audience in (
                ("core", "permesi-genesis", "genesis", "openbao"), ("core", "permesi-genesis", "permesi", "openbao"),
                ("edge", "permesi", "permesi", "openbao"), ("edge", "permesi", "genesis", "openbao"),
                ("core", "admission-reader", "admission-reader", "admission-reader")):
            require(not _login(kube, side, account, role, audience),
                    f"{side} OpenBao refuses the {account} identity for role {role}")
        for side, token, owner, operations in (
                ("core", edge_token, "edge", (["read", "secret/permesi/data/config"], ["read", "database/creds/permesi"],
                                              ["read", "secret/permesi/data/admission-authority"])),
                ("edge", core_token, "core", (["write", "transit/genesis/sign/genesis-signing", "input=aGk=", "key_version=1"],
                                              ["read", "database/creds/genesis"], ["read", SIGNING_KEY]))):
            for operation in operations:
                require(_denied(_as(kube, side, *operation), token),
                        f"{side} OpenBao denies the {owner} token: {' '.join(operation[:2])}")
        unused = run(kube + ["get", "serviceaccount", "unused-permesi", "unused-genesis", "--ignore-not-found", "-o", "name"])
        require(unused == "", "the placeholder identities bound to each side's unused peer role do not exist")
        for side, other, token, service in (("core", "edge", core_token, "permesi"), ("edge", "core", edge_token, "genesis")):
            issued = subprocess.run(_as(kube, side, "read", "-format=json", "database/creds/" + service),
                                    input=token, text=True, capture_output=True)
            require(issued.returncode == 0, f"{side} OpenBao issues {service} database credentials to its own backend")
            issued = json.loads(issued.stdout)
            try:
                username = issued["data"]["username"]
                require(_role_count(kube, side, username) == "1" and _role_count(kube, other, username) == "0",
                        f"a {service} database identity exists only in the {side} PostgreSQL")
            finally:
                run(_openbao(kube, side) + ["bao", "lease", "revoke", "-sync", issued["lease_id"]])
    finally:
        for side, token in (("core", core_token), ("edge", edge_token)):
            if token:
                subprocess.run(_openbao(kube, side) + ["bao", "write", "auth/token/revoke", "token=-"],
                               input=token, text=True, capture_output=True, check=True)
    reader = kube + ["exec", "admission-reader", "-c", "agent", "--", "bao"]
    address = "-address=unix:///run/reader/agent.sock"
    require(run(reader + ["read", address, "-field=type", SIGNING_KEY]) == "ed25519",
            "admission reader reads the public signing key")
    # Ordered so that a wrongly permitted step fails the run before a later one could
    # use it: configuration and deletion come after signing and rotation.
    for operation in (["write", address, "transit/genesis/sign/genesis-signing", "input=aGk=", "key_version=1"],
                      ["write", address, "-f", SIGNING_KEY + "/rotate"],
                      ["write", address, SIGNING_KEY + "/config", "deletion_allowed=true"],
                      ["delete", address, SIGNING_KEY],
                      ["list", address, "transit/genesis/keys"],
                      ["read", address, "database/creds/genesis"],
                      ["read", address, "secret/permesi/data/config"],
                      ["write", address, "-f", "auth/token/create"]):
        path = next(part for part in operation[2:] if not part.startswith("-"))
        require(_denied(reader + operation), f"admission reader is denied: {operation[0]} {path}")


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
            run(kube + ["rollout", "status", "deploy/" + name, "--timeout=180s"])
            deployment = json.loads(run(kube + ["get", "deployment", name, "-o", "json"]))
            selector = ",".join(k + "=" + v for k, v in deployment["spec"]["selector"]["matchLabels"].items())
            pods = json.loads(run(kube + ["get", "pods", "-l", selector, "-o", "json"]))["items"]
            pods = [pod for pod in pods if "deletionTimestamp" not in pod["metadata"]]
            require(len(pods) == deployment["status"]["readyReplicas"] == 2, f"two ready isolated-profile {service} replicas")
            image = lock["images"][service]
            for pod in pods:
                actual = next(c for c in pod["status"]["containerStatuses"] if c["name"] == service)
                require(actual["imageID"].split("@")[-1] == image["digest"], f"{service} running manifest matches record")
                if prefix:
                    version = run(kube + ["exec", pod["metadata"]["name"], "-c", service, "--", "/app/" + service, "--version"])
                    require(lock["appRevision"] in version, f"{service} binary matches application revision")
            if prefix:
                roots.append(run(kube + ["exec", "deploy/" + prefix + "-quickstart-openbao", "-c", "openbao", "--",
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
    verify_isolation(kube)
