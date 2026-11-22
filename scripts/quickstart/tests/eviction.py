"""Validate administrative eviction of a separately enrolled Genesis instance.

The disposable pod uses its own service account, OpenBao Kubernetes role and Agent.
The operator verifies TokenReview, lease removal and termination of established SQL
sessions through administrative interfaces. Workload credentials remain in their pod.
"""
import json
from pathlib import Path
import runpy
import time

helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "verify-runtime.py"))
run, require = helpers["run"], helpers["require"]


def revoke_approle(admin):
    """Fence the fixture enrollment, including unconsumed wrappers and its issued token."""
    mount = "trial-approle"
    run(admin + ["auth", "enable", "-path=" + mount, "approle"])
    try:
        path = "auth/" + mount + "/role/eviction"
        run(admin + ["write", path, "token_policies=genesis", "token_no_default_policy=true", "token_ttl=10m",
                     "secret_id_ttl=10m"])
        role_id = run(admin + ["read", "-field=role_id", path + "/role-id"])
        # Enroll a legitimate trial instance once, before withdrawal. Only its
        # accessor is retained. Administrative lookups verify revocation.
        credentials = json.loads(run(admin + ["write", "-force", "-format=json", path + "/secret-id"]))["data"]
        issued = json.loads(run(admin + ["write", "-format=json", "auth/" + mount + "/login", "-"],
                                input=json.dumps({"role_id": role_id, "secret_id": credentials.pop("secret_id")})))
        accessor = issued["auth"]["accessor"]
        del issued
        wrapped = json.loads(run(admin + ["write", "-wrap-ttl=5m", "-format=json", "-force", path + "/secret-id"]))
        wrapper = wrapped["wrap_info"]["accessor"]
        del wrapped
        # Disable minting first. Independently revoke issued service and wrapping tokens.
        run(admin + ["delete", path])
        for value in [accessor, wrapper]:
            run(admin + ["write", "auth/token/revoke-accessor", "accessor=-"], input=value)
        remaining = json.loads(run(admin + ["list", "-format=json", "auth/token/accessors"]))
        require(accessor not in remaining and wrapper not in remaining,
                "AppRole enrollment and issued service and wrapping token accessors were removed")
    finally:
        run(admin + ["auth", "disable", mount])


def trial(kube, namespace, edge):
    admin = kube + ["exec", "-i", "deploy/" + edge + "-vault", "-c", "vault", "--", "bao"]
    revoke_approle(admin)
    label = "eviction-genesis"
    def obj(kind, name):
        return json.loads(run(kube + ["get", kind, name, "-o", "json"]))
    def apply(kind, **fields):
        run(kube + ["create", "-f", "-"], input=json.dumps(dict(apiVersion="v1", kind=kind,
            metadata={"name": label, "namespace": namespace}, **fields)))
    apply("ServiceAccount", automountServiceAccountToken=False)
    run(admin + ["write", "auth/kubernetes/role/" + label, "bound_service_account_names=" + label,
                 "bound_service_account_namespaces=" + namespace, "audience=vault",
                 "token_policies=genesis,genesis-pki", "token_no_default_policy=true", "token_ttl=10m"])
    template = obj("deploy", "permesi-genesis")["spec"]["template"]["spec"]
    template["serviceAccountName"] = label
    volume = next(v["configMap"] for v in template["volumes"] if v["name"] == "vault-agent-config")
    cfg = obj("configmap", volume["name"])["data"]
    import re
    cfg["agent.hcl"], count = re.subn(r'(\brole\s*=\s*)"genesis"', r'\1"' + label + '"', cfg["agent.hcl"])
    require(count == 1, "eviction instance has its own Agent enrollment")
    volume["name"] = label
    apply("ConfigMap", data=cfg)
    app = next(c for c in template["containers"] if c["name"] == "genesis")
    app["env"].extend({"name": "GENESIS_PUBLIC_" + key, "value": "1"} for key in
                      ["REQUESTS_PER_SECOND", "BURST", "MAX_IN_FLIGHT"])
    apply("Pod", spec=template)
    run(kube + ["wait", "--for=condition=Ready", "pod/" + label, "--timeout=180s"])
    identity = obj("pod", label)
    runpy.run_path(str(Path(__file__).with_name("entry-limits.py")))["measure"](kube, identity, namespace, admin, edge)
    ip = identity["status"]["podIP"]
    from ipaddress import ip_address
    ip_address(ip)
    sql = kube + ["exec", edge + "-postgresql-0", "-c", "postgresql", "--", "psql",
                  "-X", "-U", "postgres", "-d", "postgres", "-Atc"]
    users = run(sql + [f"SELECT DISTINCT usename FROM pg_stat_activity WHERE datname='genesis' AND client_addr='{ip}'::inet"]).splitlines()
    require(bool(users), "separately enrolled pod holds real SQL sessions")
    quoted = ",".join("'" + user.replace("'", "''") + "'" for user in users)
    # Ask Kubernetes to issue a diagnostic token bound to exactly this pod/UID.
    # It is only submitted to the Kubernetes TokenReview API.
    bound = run(kube + ["create", "token", label, "--audience=vault", "--duration=10m", "--bound-object-kind=Pod",
                        "--bound-object-name=" + label, "--bound-object-uid=" + identity["metadata"]["uid"]])
    def token_review():
        body = {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
                "spec": {"token": bound, "audiences": ["vault"]}}
        status = json.loads(run(kube + ["create", "-f", "-", "-o", "json"], input=json.dumps(body)))["status"]
        return status.get("authenticated", False) and status["user"]["username"] == f"system:serviceaccount:{namespace}:{label}"
    require(token_review(), "Kubernetes authenticated the live pod-bound diagnostic identity")
    # Resolve the disposable identity from operator-visible issued-token metadata.
    def accessors():
        items = json.loads(run(admin + ["list", "-format=json", "auth/token/accessors"]))
        owned = []
        for accessor in items:
            tok = json.loads(run(admin + ["write", "-format=json", "auth/token/lookup-accessor",
                                         "accessor=-"], input=accessor))["data"]
            if (tok.get("meta") or {}).get("service_account_name") == label:
                owned.append(accessor)
        return owned
    issued = accessors()
    require(bool(issued), "operator identified the instance-specific issued Agent token")
    run(admin + ["delete", "auth/kubernetes/role/" + label])
    for value in issued:
        run(admin + ["write", "auth/token/revoke-accessor", "accessor=-"], input=value)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        roles = run(sql + [f"SELECT count(*) FROM pg_roles WHERE rolname IN ({quoted})"])
        sessions = run(sql + [f"SELECT count(*) FROM pg_stat_activity WHERE usename IN ({quoted})"])
        if roles == sessions == "0":
            break
        time.sleep(1)
    require(roles == sessions == "0", "revocation removed the login roles and terminated established SQL sessions")
    require(not accessors(), "evicted enrollment has no issued Agent token")
    run(kube + ["delete", "pod", label, "--wait=true"])
    require(not token_review(), "Kubernetes rejected the deleted pod-bound identity")
    run(kube + ["delete", "serviceaccount", label])
    run(kube + ["delete", "configmap", label])
    deployment = obj("deploy", "permesi-genesis")
    require(deployment["status"]["readyReplicas"] == 2, "both independently enrolled sibling replicas remain ready")
