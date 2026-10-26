#!/usr/bin/env python3
"""Exercise real chart consumers, including discovery values Helm's CLI normalizes."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / "docs/examples/vault-agent-stack.yaml"


class ChartContracts(unittest.TestCase):
    def test_passthrough_profile_does_not_trust_forwarded_headers(self):
        """An encrypted TCP proxy cannot establish HTTP header provenance."""
        with tempfile.TemporaryDirectory() as directory:
            values = Path(directory) / "values.yaml"
            values.write_text(yaml.safe_dump(yaml.safe_load(PROFILE.read_text())["permesi"]))
            result = subprocess.run(
                ["helm", "template", "permesi", str(ROOT / "charts/permesi"),
                 "-n", "permesi", "-f", str(values), "--kube-version", "1.30.0"],
                capture_output=True, text=True, check=True,
            )
        objects = list(yaml.safe_load_all(result.stdout))
        ingress = next(obj for obj in objects if obj and obj["kind"] == "Ingress")
        self.assertEqual(ingress["metadata"]["annotations"][
            "nginx.ingress.kubernetes.io/ssl-passthrough"], "true")
        deployment = next(obj for obj in objects if obj and obj["kind"] == "Deployment")
        app = next(c for c in deployment["spec"]["template"]["spec"]["containers"]
                   if c["name"] == "permesi")
        self.assertFalse(any(e["name"] in ("PERMESI_AUTH_TRUSTED_PROXIES",
                                         "PERMESI_AUTH_TRUST_UNIX_PROXY")
                             for e in app.get("env", [])))

    def test_discovery_minor_suffix_preserves_supported_version_check(self):
        """Invoke actual validation with discovery-shaped capabilities, not --kube-version."""
        profile = yaml.safe_load(PROFILE.read_text())
        with tempfile.TemporaryDirectory() as directory:
            for service in ("permesi", "genesis"):
                chart = Path(directory) / service
                (chart / "templates").mkdir(parents=True)
                source = ROOT / "charts" / service
                for name in ("Chart.yaml", "values.yaml", "values.schema.json"):
                    shutil.copyfile(source / name, chart / name)
                for template in (source / "templates").glob("*.tpl"):
                    shutil.copyfile(template, chart / "templates" / template.name)
                values = chart / "effective.yaml"
                values.write_text(yaml.safe_dump(profile[service]))
                for minor, supported in (("29", True), ("29+", True), ("30+", True),
                                         ("28", False), ("28+", False), ("invalid", False)):
                    with self.subTest(service=service, minor=minor):
                        context = ('dict "Values" .Values "Chart" .Chart "Release" .Release '
                                   '"Capabilities" (dict "KubeVersion" (dict "Major" "1" '
                                   '"Minor" ' + json.dumps(minor) + '))')
                        (chart / "templates/probe.yaml").write_text(
                            '{{- include "' + service + '.validateValues" (' + context + ') -}}\n'
                            'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: probe\n')
                        result = subprocess.run(
                            ["helm", "template", "probe", str(chart), "-n", "permesi",
                             "-f", str(values)], capture_output=True, text=True,
                        )
                        if supported:
                            self.assertEqual(result.returncode, 0, result.stderr)
                        else:
                            self.assertNotEqual(result.returncode, 0)
                            self.assertIn("requires Kubernetes >= 1.29", result.stderr)


if __name__ == "__main__":
    unittest.main()
