#!/usr/bin/env python3
"""Exercise native Helm rollback admission in a fresh namespace on a disposable cluster.

This isolates the operator-owned admission decision. Application readiness and
withdrawal convergence require live replicas in the separate service trials.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    for image in ("legacy", "previous", "current"):
        parser.add_argument("--" + image, required=True, help="complete image repository@digest")
    args = parser.parse_args()
    if len({args.legacy, args.previous, args.current}) != 3:
        parser.error("provide three distinct immutable images")
    namespace = "core-policy-" + uuid.uuid4().hex[:12]
    kube = ["kubectl", "--context", args.context, "-n", namespace]
    helm = ["helm", "--kube-context", args.context, "-n", namespace]
    policy = subprocess.check_output(["python3", str(ROOT / "scripts/ci/core-image-policy.py"),
        "--namespace", namespace, "--deployment", "permesi", "--service-account", "permesi",
        "--image", args.previous, "--image", args.current], text=True)
    subprocess.run(kube + ["create", "namespace", namespace], check=True)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp)
            (chart / "templates").mkdir()
            (chart / "Chart.yaml").write_text("apiVersion: v2\nname: permesi\nversion: 1.0.0\n")
            (chart / "templates/deploy.yaml").write_text("""apiVersion: apps/v1
kind: Deployment
metadata: {name: permesi}
spec:
  replicas: 0
  selector: {matchLabels: {app: permesi}}
  template:
    metadata: {labels: {app: permesi}}
    spec:
      serviceAccountName: permesi
      containers:
        - {name: permesi, image: {{ .Values.image | quote }}}
""")
            for image in [args.legacy, args.previous, args.current]:
                subprocess.run(helm + ["upgrade", "--install", "permesi", str(chart),
                                      "--set-string", "image=" + image], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(kube + ["apply", "-f", "-"], input=policy, text=True, check=True)
            subprocess.run(helm + ["rollback", "permesi", "2", "--wait"], check=True)
            def live_image():
                return json.loads(subprocess.check_output(kube + ["get", "deployment", "permesi", "-o", "json"]))[
                    "spec"]["template"]["spec"]["containers"][0]["image"]
            if live_image() != args.previous:
                raise RuntimeError("qualified rollback did not restore the previous digest")
            denied = subprocess.run(helm + ["rollback", "permesi", "1"], capture_output=True, text=True)
            if denied.returncode == 0 or "operator-qualified image digest" not in denied.stderr or live_image() != args.previous:
                raise RuntimeError("expected the digest policy to reject native legacy rollback and retain the qualified image")
            print("PASS: native Helm rollback restored the qualified digest and denied the legacy digest")
    finally:
        try:
            subprocess.run(kube + ["delete", "--ignore-not-found", "-f", "-"], input=policy, text=True, check=True)
        finally:
            subprocess.run(kube + ["delete", "namespace", namespace, "--wait=true"], check=True)


if __name__ == "__main__":
    main()
