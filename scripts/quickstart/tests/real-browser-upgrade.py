#!/usr/bin/env python3
"""Upgrade published images to candidate images with real browser credentials.

Owns an absent qv-browser-* namespace and rootless Podman test containers. A
loopback-only TLS edge verifies backend certificates; Chromium trusts the public
test CA in its disposable container, with no host trust or cookie-policy changes.
Mailbox links and private material stay in memory or private temporary files.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import socket
import subprocess
import tempfile
import uuid

import yaml

QUICKSTART = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_runtime", QUICKSTART / "verify-runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        if Path(command[0]).name == "helm" and result.stderr:
            # This fixture passes only public settings/Secret references to Helm.
            raise RuntimeError("Helm qualification failed: " + result.stderr.splitlines()[0])
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
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--browser-image", default="localhost/permesi-scenario-browser:1")
    parser.add_argument("--password-only", action="store_true",
                        help="Qualify password/MFA and record preservation; does not qualify passkey login")
    args = parser.parse_args()
    require(args.namespace.startswith("qv-browser-"), "browser namespace is explicitly disposable")
    k = ["kubectl", "--context", args.context, "-n", args.namespace]
    h = ["helm", "--kube-context", args.context, "-n", args.namespace]
    require(not run(k + ["get", "namespace", args.namespace, "--ignore-not-found", "-o", "name"]),
            "browser namespace does not already exist")
    helper = "permesi-quickstart"
    root = k + ["exec", "-i", "deploy/" + helper + "-vault", "-c", "vault", "--", "vault"]
    revision = run(["git", "-C", str(args.app_source), "rev-parse", "HEAD"])
    baseline = json.loads((QUICKSTART / "lock.json").read_text())["images"]
    candidate = json.loads((args.fixture / "scripts/quickstart/lock.json").read_text())["images"]
    unique = uuid.uuid4().hex[:10]
    edge_name = "permesi-edge-" + unique
    browser_name = "permesi-browser-" + unique
    browser = None
    forwards = {}
    port = socket.socket()
    port.bind(("127.0.0.1", 0))
    browser_port = port.getsockname()[1]
    origin = f"https://localhost:{browser_port}"

    def sql(query):
        return run(k + ["exec", helper + "-postgresql-0", "-c", "postgresql", "--",
                        "psql", "-X", "-U", "postgres", "-d", "permesi", "-tAc", query])

    def deployed_images(expected):
        pods = json.loads(run(k + ["get", "pods", "-o", "json"]))["items"]
        counts = {service: 0 for service in ("permesi", "genesis", "web")}
        for pod in pods:
            if pod["metadata"].get("deletionTimestamp"):
                continue
            for container in pod["spec"]["containers"]:
                service = container["name"]
                if service not in counts:
                    continue
                identity = expected[service]
                wanted = identity["repository"] + "@" + identity["digest"]
                status = next(s for s in pod["status"]["containerStatuses"] if s["name"] == service)
                require(container["image"] == wanted and identity["digest"] in status["imageID"] and status["ready"],
                        service + ": running image ID matches selected manifest")
                counts[service] += 1
        require(all(count == 2 for count in counts.values()), "two active replicas use each selected image")

    run(k + ["create", "namespace", args.namespace])
    try:
        run(k + ["label", "namespace", args.namespace, "pod-security.kubernetes.io/enforce=restricted"])
        files = sorted((args.app_source / "db/sql").glob("*.sql"))
        run(k + ["create", "configmap", "qualification-sql"] + ["--from-file=" + str(file) for file in files])
        with tempfile.TemporaryDirectory(prefix="browser-upgrade-") as directory:
            directory = Path(directory)
            public = directory / "public"
            public.mkdir()
            run(["bash", str(QUICKSTART / "install.sh"), "--context", args.context,
                 "--namespace", args.namespace, "--release", "permesi", "--deps-only",
                 "--acknowledge-development", "--app-source", str(args.app_source)])
            profile = yaml.safe_load((args.fixture / "charts/permesi-stack/examples/quickstart.yaml").read_text())
            # The embedded quickstart intentionally fixes its browser endpoints.
            # Use the supported external-dependency umbrella mode for this TLS edge.
            profile["quickstart"]["enabled"] = False
            for service, name in (("permesi", "permesi"), ("genesis", "permesi-genesis")):
                component = profile[service]
                component["database"]["dsn"]["value"] = f"postgres://placeholder@{helper}-postgresql.{args.namespace}.svc:5432/{service}?sslmode=disable"
                agent = component["vault"]["agent"]
                agent["address"] = f"http://{helper}-vault.{args.namespace}.svc:8200"
                agent["pki"]["commonName"] = f"{name}.{args.namespace}.svc.cluster.local"
                agent["pki"]["dnsNames"] = [name, f"{name}.{args.namespace}", f"{name}.{args.namespace}.svc",
                    f"{name}.{args.namespace}.svc.cluster.local", "api.localhost" if service == "permesi" else "genesis.localhost"]
            profile["permesi"]["admission"]["paserkUrl"] = f"https://permesi-genesis.{args.namespace}.svc.cluster.local:8080/paserk.json"
            profile["permesi"]["auth"]["frontendBaseUrl"] = origin
            profile["permesi"]["auth"]["corsAllowedOrigins"] = origin
            profile["web"]["runtimeConfig"]["apiBaseUrl"] = origin
            profile["web"]["runtimeConfig"]["tokenBaseUrl"] = origin + "/genesis"
            profile["quickstart"]["bootstrap"]["schema"] = {
                "sourceUrl": "", "sha256": "", "revision": revision,
                "existingConfigMaps": ["qualification-sql"]}
            values_path = directory / "values.json"
            archives = directory / "packages"
            archives.mkdir()
            for chart in ("permesi", "genesis", "web", "permesi-stack"):
                run(["helm", "package", str(args.fixture / "charts" / chart), "-d", str(archives)])
            package = next(archives.glob("permesi-stack-*.tgz"))

            def install(images):
                for service in ("permesi", "genesis", "web"):
                    profile[service]["image"] = {**images[service],
                        "pullPolicy": "Never" if images is candidate else "IfNotPresent"}
                values_path.write_text(json.dumps(profile))
                run(h + ["upgrade", "--install", "permesi", str(package), "--reset-values",
                         "-f", str(values_path), "--wait", "--wait-for-jobs", "--timeout", "600s"])

            install(baseline)
            deployed_images(baseline)
            require(True, "packaged umbrella runs published baseline applications with exact current SQL")
            ca = run(root + ["read", "-field=certificate", "pki-root/cert/ca"]) + "\n"
            (public / "root.pem").write_text(ca)
            run(root + ["write", "pki-int/roles/qualification-web", "allowed_domains=localhost",
                        "allow_bare_domains=true", "allow_subdomains=false", "allow_localhost=true", "max_ttl=1h"])
            certificate = json.loads(run(root + ["write", "-format=json", "pki-int/issue/qualification-web",
                                                 "common_name=localhost", "ttl=30m"]))["data"]
            key = directory / "edge-key.pem"
            key.write_text(certificate["private_key"])
            key.chmod(0o600)
            (directory / "edge-chain.pem").write_text("\n".join([certificate["certificate"], *certificate["ca_chain"]]))
            del certificate
            (directory / "root.pem").write_text(ca)
            for service, name in (("permesi", "permesi"), ("genesis", "permesi-genesis"), ("web", "permesi-web")):
                forwards[service] = runtime.PortForward(k, "svc/" + name)
            nginx = f'''pid /tmp/nginx.pid;
events {{}}
http {{
  access_log off;
  server {{
    listen 127.0.0.1:{browser_port} ssl;
    ssl_certificate /qualification/edge-chain.pem;
    ssl_certificate_key /qualification/edge-key.pem;
    proxy_ssl_trusted_certificate /qualification/root.pem;
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 3;
    proxy_ssl_server_name on;
    location /v1/ {{
      proxy_set_header Host api.localhost;
      proxy_ssl_name api.localhost;
      proxy_pass https://127.0.0.1:{forwards['permesi'].port};
    }}
    location /genesis/ {{
      proxy_set_header Host genesis.localhost;
      proxy_ssl_name genesis.localhost;
      proxy_pass https://127.0.0.1:{forwards['genesis'].port}/;
    }}
    location / {{ proxy_pass http://127.0.0.1:{forwards['web'].port}; }}
  }}
}}'''
            (directory / "nginx.conf").write_text(nginx)
            port.close()
            run(["podman", "run", "-d", "--name", edge_name, "--network", "host", "--user", "0",
                 "-v", f"{directory}:/qualification:ro", "-v", f"{directory}/nginx.conf:/etc/nginx/nginx.conf:ro",
                 "docker.io/nginxinc/nginx-unprivileged:stable-alpine"])
            run(["curl", "--noproxy", "*", "--retry", "10", "--retry-connrefused", "--retry-delay", "1",
                 "--cacert", str(public / "root.pem"), "-fsS", origin + "/config.js"])
            shutil.copyfile(QUICKSTART / "tests/browser-upgrade.mjs", public / "browser-upgrade.mjs")
            command = ['mkdir -p /root/.pki/nssdb',
                       'certutil -N --empty-password -d sql:/root/.pki/nssdb',
                       'certutil -A -d sql:/root/.pki/nssdb -n qualification-root -t "C,," -i /qualification/root.pem',
                       'exec node /qualification/browser-upgrade.mjs']
            browser = subprocess.Popen(["podman", "run", "--rm", "-i", "--name", browser_name,
                "--network", "host", "--entrypoint", "sh", "-e", "QS_BROWSER_ORIGIN=" + origin,
                "-e", "QS_BROWSER_PASSWORD_ONLY=" + str(args.password_only).lower(),
                "-v", f"{public}:/qualification:ro", args.browser_image, "-ec", "\n".join(command)],
                text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            def message():
                with selectors.DefaultSelector() as selector:
                    selector.register(browser.stdout, selectors.EVENT_READ)
                    require(bool(selector.select(180)), "browser stage completed within its deadline")
                line = browser.stdout.readline()
                if not line:
                    raise RuntimeError("browser qualification stopped: " + browser.stderr.read().strip())
                return json.loads(line)

            account = message()
            email = account.get("email", "")
            require(account.get("event") == "account-created" and bool(re.fullmatch(r"browser-[a-f0-9]+@example.test", email)),
                    "real browser performed OPAQUE signup against baseline images")
            payload = json.loads(sql("SELECT payload_json FROM email_outbox WHERE to_email='" + email + "' ORDER BY created_at DESC LIMIT 1"))
            browser.stdin.write(json.dumps({"verifyUrl": payload["verify_url"]}) + "\n")
            browser.stdin.flush()
            del payload
            require(message().get("event") == "baseline-ready", "baseline mailbox, password, MFA and stored passkey flows succeed")
            record_query = ("SELECT md5(u.opaque_registration_record::text || string_agg(p.credential_id::text || p.passkey_data::text,',' ORDER BY p.credential_id)),count(*) "
                            "FROM users u JOIN passkeys p ON p.user_id=u.id WHERE u.email='" + email + "' GROUP BY u.id")
            before = sql(record_query)
            require(before.endswith("|1"), "baseline contains exactly one persisted browser passkey")
            install(candidate)
            deployed_images(candidate)
            require(sql(record_query) == before, "image upgrade preserves OPAQUE and passkey records byte-for-byte")
            # kubectl forwards attach to a specific pod even when targeting a
            # Service. Reconnect after rollout while keeping the browser origin.
            old_ports = {service: forward.port for service, forward in forwards.items()}
            for service, name in (("permesi", "permesi"), ("genesis", "permesi-genesis"), ("web", "permesi-web")):
                forwards[service].close()
                forwards[service] = runtime.PortForward(k, "svc/" + name)
                nginx = nginx.replace(f"127.0.0.1:{old_ports[service]}", f"127.0.0.1:{forwards[service].port}")
            (directory / "nginx.conf").write_text(nginx)
            run(["podman", "restart", edge_name])
            run(["curl", "--noproxy", "*", "--retry", "10", "--retry-all-errors", "--retry-delay", "1",
                 "--cacert", str(public / "root.pem"), "-fsS", origin + "/login"])
            browser.stdin.write('{"upgraded":true}\n')
            browser.stdin.flush()
            require(message().get("event") == "password-upgrade-passed", "existing OPAQUE account signs in with MFA after image upgrade")
            if args.password_only:
                print("INFO: limited qualification: passkey authentication was not tested", flush=True)
            else:
                require(message().get("event") == "passkey-upgrade-passed", "existing browser passkey authenticates after image upgrade")
            require(browser.wait(timeout=15) == 0, "browser upgrade qualification exits successfully")
    finally:
        port.close()
        for container in (browser_name, edge_name):
            run(["podman", "rm", "-f", "--ignore", container])
        if browser:
            browser.wait(timeout=15)
        for forward in forwards.values():
            forward.close()
        run(h + ["uninstall", "permesi", "--ignore-not-found"])
        run(h + ["uninstall", helper, "--ignore-not-found"])
        run(k + ["delete", "namespace", args.namespace, "--ignore-not-found", "--wait=true"])


if __name__ == "__main__":
    main()
