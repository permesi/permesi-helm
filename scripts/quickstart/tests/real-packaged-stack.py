#!/usr/bin/env python3
"""Install, verify and reinstall the packaged embedded umbrella in an owned namespace.

Uses the exact locked application checkout and immutable images. PostgreSQL, Vault,
bootstrap and all applications are installed by the packaged umbrella itself.
"""
import argparse
import hashlib
import json
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import tarfile

import yaml

ROOT = Path(__file__).resolve().parents[3]


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed (exit {result.returncode}); private diagnostics withheld")
    return result.stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)
    print("PASS: " + message, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, default=ROOT)
    parser.add_argument("--admission-bin", default=os.environ.get("QS_ADMISSION_BIN"), required=False)
    parser.add_argument("--previous-core", help="previous qualified core repository@digest for native rollback")
    parser.add_argument("--previous-revision", help="full build commit embedded in the previous core")
    parser.add_argument("--profile", choices=("shared", "isolated"), default="shared")
    parser.add_argument("--openbao-image", help="Pinned OpenBao repository@digest for the containment fixture")
    parser.add_argument("--postgres-image", help="Pinned PostgreSQL repository@digest for the containment fixture")
    args = parser.parse_args()
    if bool(args.previous_core) != bool(args.previous_revision) or (args.previous_core and not args.openbao_image):
        parser.error("binary rollback requires both previous image and revision in a candidate profile")
    if args.profile == "isolated" and not args.openbao_image:
        parser.error("isolated qualification requires OpenBao")
    if bool(args.openbao_image) != bool(args.postgres_image):
        parser.error("supply both dependency images")
    require(bool(args.admission_bin) and Path(args.admission_bin).is_file(), "actual admission client is available")
    lock = json.loads((args.fixture / "scripts/quickstart/lock.json").read_text())
    require(run(["git", "-C", str(args.app_source), "rev-parse", "HEAD"]) == lock["appRevision"],
            "packaged stack SQL checkout matches the qualification revision")
    require(not run(["git", "-C", str(args.app_source), "status", "--porcelain", "--", "db/sql"]),
            "packaged stack SQL checkout is clean")
    if args.openbao_image:
        archive = args.fixture / "application-sql.tar.gz"
        require(run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]) == lock["chartRevision"],
                "chart checkout matches the qualification record")
        require(hashlib.sha256(archive.read_bytes()).hexdigest() == lock["appArchiveSha256"],
                "SQL archive checksum matches the qualification record")
        with tarfile.open(archive) as contents:
            prefix = f"permesi-{lock['appRevision']}/db/sql/"
            files = {m.name.removeprefix(prefix): contents.extractfile(m).read()
                     for m in contents if m.isfile() and m.name.startswith(prefix) and m.name.endswith(".sql")}
        checkout = args.app_source / "db/sql"
        require(files == {str(p.relative_to(checkout)): p.read_bytes() for p in checkout.rglob("*.sql")}
                and all("/" not in name for name in files),
                "every SQL input matches the exact archive and can be mounted by the flat bootstrap")
    namespace = "permesi-isolated" if args.profile == "isolated" else "permesi-quickstart"
    k = ["kubectl", "--context", args.context, "-n", namespace]
    h = ["helm", "--kube-context", args.context, "-n", namespace]
    require(not run(k + ["get", "namespace", namespace, "--ignore-not-found", "-o", "name"]),
            "fixed embedded-profile namespace does not already exist")
    run(k + ["create", "namespace", namespace])
    policy = None
    try:
        run(k + ["label", "namespace", namespace, "pod-security.kubernetes.io/enforce=restricted"])
        sql_files = sorted((args.app_source / "db/sql").glob("*.sql"))
        require(bool(sql_files), "canonical SQL files are present")
        configmaps = []
        for index, path in enumerate(sql_files):
            require(path.stat().st_size < 524288 and not path.is_symlink(), "SQL file fits the bounded ConfigMap budget")
            name = "qualification-sql-" + str(index)
            run(k + ["create", "configmap", name, "--from-file=" + str(path)])
            configmaps.append(name)
        charts = args.fixture / "charts"
        run(["helm", "dependency", "build", str(charts / "permesi-stack")])
        with tempfile.TemporaryDirectory(prefix="packaged-stack-") as directory:
            directory = Path(directory)
            run(["helm", "package", str(charts / "permesi-stack"), "-d", str(directory)])
            package = next(directory.glob("permesi-stack-*.tgz"))
            profile_values = (charts / "permesi-stack/examples/quickstart.yaml").read_text()
            values = yaml.safe_load(profile_values.replace(".permesi-quickstart", "." + namespace))
            values["quickstart"]["bootstrap"]["schema"] = {
                "sourceUrl": "", "sha256": "", "revision": lock["appRevision"],
                "existingConfigMaps": configmaps}
            for service in ("permesi", "genesis", "web"):
                image = lock["images"][service]
                values[service]["image"] = {**image,
                    "pullPolicy": "Never" if image["repository"].startswith("localhost/") else "IfNotPresent"}
            if args.openbao_image:
                def pinned(reference):
                    repository, digest = reference.split("@")
                    return {"repository": repository, "digest": digest, "pullPolicy": "IfNotPresent"}
                quickstart = values["quickstart"]
                quickstart.update(secretsProvider="openbao", vault={"image": pinned(args.openbao_image)},
                                  postgresql={"image": pinned(args.postgres_image)})
                for svc in ("permesi", "genesis"):
                    values[svc]["secretsProvider"] = "openbao"
                    values[svc]["vault"]["agent"]["image"] = pinned(args.openbao_image)
                values["permesi"]["admission"]["paserkUrl"] = ""
                values["permesi"]["vault"]["agent"]["paserkCa"]["enabled"] = False
            isolated = args.profile == "isolated"
            reader = None
            core = edge = "permesi-quickstart"
            if isolated:
                isolated_checks = runpy.run_path(str(Path(__file__).with_name("isolated-dependencies.py")))
                reader = isolated_checks["install_dependencies"](k, h, args.fixture, values, directory, namespace)
                core, edge = "core-quickstart", "edge-quickstart"
            values_file = directory / "values.json"
            values_file.write_text(json.dumps(values))
            install = h + ["upgrade", "--install", "permesi", str(package), "-f", str(values_file),
                           "--reset-values", "--wait", "--wait-for-jobs", "--timeout", "600s"]
            verify = ["bash", str(args.fixture / "scripts/quickstart/verify.sh"),
                "--context", args.context, "--namespace", namespace, "--release", "permesi",
                "--helper-release", "permesi", "--helper-fullname", "permesi-quickstart"]
            environment = {**os.environ, "QS_ADMISSION_BIN": args.admission_bin}
            def records():
                return run(k + ["exec", core + "-postgresql-0", "-c", "postgresql", "--",
                    "psql", "-X", "-U", "postgres", "-d", "permesi", "-tAc",
                    "SELECT count(*)||':'||coalesce(md5(string_agg(id::text||email||coalesce(encode(opaque_registration_record,'hex'),'<null>'),',' ORDER BY id)),'empty') FROM users"])
            run(install)
            if args.openbao_image:
                # Operator action outside the release. CAS zero protects an existing withdrawal floor.
                operator = k + ["exec", "-i", "deploy/" + core + "-vault", "-c", "vault", "--", "bao"]
                metadata = json.loads(run((reader or operator + ["read"]) + ["-format=json", "transit/genesis/keys/genesis-signing"]))["data"]
                require(metadata["type"] == "ed25519", "bootstrap signer is Ed25519")
                payload = {"minimum_version": 1, "keys": {"1": metadata["keys"]["1"]["public_key"]}}
                run(operator + ["kv", "put", "-mount=secret/permesi", "-cas=0", "admission-authority", "-"],
                    input=json.dumps(payload))
            def verify_profile():
                if isolated:
                    isolated_checks["verify"](k, lock, args.admission_bin, namespace)
                else:
                    require("verify.sh: ALL CHECKS PASSED" in run(verify, env=environment),
                            "packaged embedded stack passes real TLS/admission and dependency policy verification")
            verify_profile()
            before = records()
            require(not before.startswith("0:"), "real signup created protected application records")
            run(install)
            require(records() == before, "packaged umbrella reinstall preserves existing OPAQUE records")
            verify_profile()
            rollback = None
            if args.previous_core:
                identity = lock["images"]["permesi"]
                current = identity["repository"] + "@" + identity["digest"]
                require(args.previous_core != current and args.previous_revision != lock["appRevision"],
                        "binary rollback uses distinct revisions and immutable images")
                policy = run(["python3", str(ROOT / "scripts/ci/core-image-policy.py"), "--namespace", namespace,
                              "--deployment", "permesi", "--service-account", "permesi", "--image", current,
                              "--image", args.previous_core])
                run(k + ["apply", "-f", "-"], input=policy)
                repo, digest = args.previous_core.split("@")
                def verify_previous():
                    run(k + ["rollout", "status", "deploy/permesi", "--timeout=120s"])
                    deploy = json.loads(run(k + ["get", "deploy", "permesi", "-o", "json"]))
                    selector = ",".join(key + "=" + val for key, val in deploy["spec"]["selector"]["matchLabels"].items())
                    pods = json.loads(run(k + ["get", "pods", "-l", selector, "-o", "json"]))["items"]
                    pods = [p for p in pods if "deletionTimestamp" not in p["metadata"]]
                    require(len(pods) == deploy["status"]["readyReplicas"] == 2, "both rollback replicas are ready")
                    for pod in pods:
                        status = next(s for s in pod["status"]["containerStatuses"] if s["name"] == "permesi")
                        require(status["imageID"].split("@")[-1] == digest and args.previous_revision in
                                run(k + ["exec", pod["metadata"]["name"], "-c", "permesi", "--", "/app/permesi", "--version"]),
                                "running core image and binary match the previous revision")
                run(install + ["--set-string", "permesi.image.repository=" + repo,
                               "--set-string", "permesi.image.digest=" + digest])
                verify_previous()
                revision = json.loads(run(h + ["status", "permesi", "-o", "json"]))["version"]
                run(install)
                verify_profile()
                def rollback():
                    run(h + ["rollback", "permesi", str(revision), "--wait", "--timeout", "120s"])
                    verify_previous()
            if args.openbao_image:
                runpy.run_path(str(Path(__file__).with_name("admission-containment.py")))["trial"](k, core, edge, reader, rollback)
    finally:
        try:
            if policy:
                run(k + ["delete", "--ignore-not-found", "-f", "-"], input=policy)
            for release in (["permesi", "core-quickstart", "edge-quickstart"] if args.profile == "isolated" else ["permesi"]):
                run(h + ["uninstall", release, "--ignore-not-found"])
        finally:
            run(k + ["delete", "namespace", namespace, "--ignore-not-found", "--wait=true"])


if __name__ == "__main__":
    main()
