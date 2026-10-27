#!/usr/bin/env python3
"""Install, verify and reinstall the packaged embedded umbrella in an owned namespace.

Uses the exact locked application checkout and immutable images. PostgreSQL, Vault,
bootstrap and all applications are installed by the packaged umbrella itself.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

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
    args = parser.parse_args()
    require(bool(args.admission_bin) and Path(args.admission_bin).is_file(), "actual admission client is available")
    lock = json.loads((args.fixture / "scripts/quickstart/lock.json").read_text())
    require(run(["git", "-C", str(args.app_source), "rev-parse", "HEAD"]) == lock["appRevision"],
            "packaged stack SQL checkout matches the qualification revision")
    require(not run(["git", "-C", str(args.app_source), "status", "--porcelain", "--", "db/sql"]),
            "packaged stack SQL checkout is clean")
    namespace = "permesi-quickstart"
    k = ["kubectl", "--context", args.context, "-n", namespace]
    h = ["helm", "--kube-context", args.context, "-n", namespace]
    require(not run(k + ["get", "namespace", namespace, "--ignore-not-found", "-o", "name"]),
            "fixed embedded-profile namespace does not already exist")
    run(k + ["create", "namespace", namespace])
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
            values = yaml.safe_load((charts / "permesi-stack/examples/quickstart.yaml").read_text())
            values["quickstart"]["bootstrap"]["schema"] = {
                "sourceUrl": "", "sha256": "", "revision": lock["appRevision"],
                "existingConfigMaps": configmaps}
            for service in ("permesi", "genesis", "web"):
                image = lock["images"][service]
                values[service]["image"] = {**image,
                    "pullPolicy": "Never" if image["repository"].startswith("localhost/") else "IfNotPresent"}
            values_file = directory / "values.json"
            values_file.write_text(json.dumps(values))
            install = h + ["upgrade", "--install", "permesi", str(package), "-f", str(values_file),
                           "--reset-values", "--wait", "--wait-for-jobs", "--timeout", "600s"]
            verify = ["bash", str(args.fixture / "scripts/quickstart/verify.sh"),
                "--context", args.context, "--namespace", namespace, "--release", "permesi",
                "--helper-release", "permesi", "--helper-fullname", "permesi-quickstart"]
            environment = {**os.environ, "QS_ADMISSION_BIN": args.admission_bin}
            def records():
                return run(k + ["exec", "permesi-quickstart-postgresql-0", "-c", "postgresql", "--",
                    "psql", "-X", "-U", "postgres", "-d", "permesi", "-tAc",
                    "SELECT count(*)||':'||coalesce(md5(string_agg(id::text||email||encode(opaque_registration_record,'hex'),',' ORDER BY id)),'empty') FROM users"])
            run(install)
            require("verify.sh: ALL CHECKS PASSED" in run(verify, env=environment),
                    "packaged embedded stack passes real TLS/admission and dependency policy verification")
            before = records()
            require(not before.startswith("0:"), "real signup created protected application records")
            run(install)
            require(records() == before, "packaged umbrella reinstall preserves existing OPAQUE records")
            require("verify.sh: ALL CHECKS PASSED" in run(verify, env=environment),
                    "reinstalled packaged embedded stack passes the common full verifier")
    finally:
        try:
            run(h + ["uninstall", "permesi", "--ignore-not-found"])
        finally:
            run(k + ["delete", "namespace", namespace, "--ignore-not-found", "--wait=true"])


if __name__ == "__main__":
    main()
