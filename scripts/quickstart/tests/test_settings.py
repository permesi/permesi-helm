#!/usr/bin/env python3
"""Validate effective settings at the Helm-to-shell configuration boundary."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "settings.py"


class SettingsTests(unittest.TestCase):
    def values(self):
        return {"postgresql": {"service": {"name": "", "port": 5432}},
                "vault": {"service": {"name": "", "port": 8200}},
                "bootstrap": {"oidcSigning": {"enabled": True},
                              "credentialsSecret": "fixture-secret-not-for-output"}}

    def run_settings(self, values):
        return subprocess.run([sys.executable, str(SCRIPT), "--fullname", "fixture",
                               "--namespace", "qv-settings"],
                              input=json.dumps(values), capture_output=True, text=True)

    def test_standalone_and_umbrella_resolve_identically_without_credentials(self):
        values = self.values()
        standalone = self.run_settings(values)
        umbrella = self.run_settings({"quickstart": values, "permesi": {}})
        self.assertEqual(standalone.returncode, 0, standalone.stderr)
        self.assertEqual(umbrella.returncode, 0, umbrella.stderr)
        self.assertEqual(standalone.stdout, umbrella.stdout)
        self.assertNotIn("fixture-secret-not-for-output", standalone.stdout)
        result = json.loads(standalone.stdout)
        self.assertEqual(result["postgres_host"], "fixture-postgresql.qv-settings.svc")
        self.assertEqual(result["vault_address"], "http://fixture-vault.qv-settings.svc:8200")

    def test_missing_ambiguous_and_malformed_settings_fail_closed(self):
        cases = [{}, {"quickstart": self.values(), **self.values()}]
        for path, value in ((("bootstrap", "oidcSigning", "enabled"), "false"),
                            (("vault", "service", "port"), True),
                            (("vault", "service", "name"), False),
                            (("postgresql", "service", "port"), 65536),
                            (("postgresql", "service", "name"), "name/with?injection")):
            values = copy.deepcopy(self.values())
            target = values
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            cases.append(values)
        for values in cases:
            with self.subTest(values=values):
                result = self.run_settings(values)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("fixture-secret-not-for-output", result.stderr)


if __name__ == "__main__":
    unittest.main()
