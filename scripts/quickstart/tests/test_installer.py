#!/usr/bin/env python3
"""Run the real installer through generated application values without a cluster."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[3]

FAKE_TOOL = '''#!PYTHON
import json, os, pathlib, sys
import yaml
args = sys.argv[1:]
if pathlib.Path(sys.argv[0]).name == 'kubectl':
    if 'get' in args and 'job' in args:
        print('1')
    elif 'get' in args and 'namespace' in args:
        print('restricted')
    elif 'config' in args or 'version' in args:
        pass
    else:
        raise SystemExit('unexpected kubectl call: ' + repr(args))
elif 'template' in args:
    print('apiVersion: v1\\nkind: ConfigMap\\nmetadata:\\n  name: preflight')
elif 'history' in args:
    print('[{"revision":1}]')
elif 'get' in args and 'values' in args:
    print(os.environ['HELPER_VALUES'])
elif 'upgrade' in args:
    if '-f' in args:
        values = yaml.safe_load(pathlib.Path(args[args.index('-f')+1]).read_text())
        release = args[args.index('--install')+1]
        with open(os.environ['CAPTURE'], 'a') as output:
            output.write(json.dumps({'release': release, 'values': values}) + '\\n')
else:
    raise SystemExit('unexpected helm call: ' + repr(args))
'''


class InstallerTests(unittest.TestCase):
    def test_custom_service_endpoints_reach_both_application_values(self):
        """Check the actual Helm -f payloads consumed by the backend charts."""
        values = {
            "postgresql": {"service": {"name": "qs-database", "port": 15432}},
            "vault": {"service": {"name": "qs-vault", "port": 18200}},
            "bootstrap": {"oidcSigning": {"enabled": True}},
        }
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            capture = scratch / "capture"
            for binary in ("helm", "kubectl"):
                path = scratch / binary
                path.write_text(FAKE_TOOL.replace("#!PYTHON", "#!" + sys.executable))
                path.chmod(0o700)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/quickstart/install.sh"), "--context", "fixture",
                 "--namespace", "qv-endpoints", "--acknowledge-development"],
                env={**os.environ, "PATH": str(scratch) + os.pathsep + os.environ["PATH"],
                     "CAPTURE": str(capture), "HELPER_VALUES": json.dumps(values)},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            releases = [json.loads(line) for line in capture.read_text().splitlines()]
        self.assertEqual(len(releases), 2)
        for release in releases:
            app = release["values"]
            self.assertIn("@qs-database.qv-endpoints.svc:15432/", app["database"]["dsn"]["value"])
            self.assertEqual(app["vault"]["agent"]["address"],
                             "http://qs-vault.qv-endpoints.svc:18200")


if __name__ == "__main__":
    unittest.main()
