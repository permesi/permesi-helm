#!/usr/bin/env python3
"""Run actual verifier sections against explicit lifecycle and policy fixtures.

These tests check shell control flow; the real-cluster regression driver supplies
the independent database/Vault proof and protected-state assertions.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VERIFY = Path(__file__).resolve().parents[1] / "verify.sh"


class VerifierTests(unittest.TestCase):
    def source(self, start, end):
        source = VERIFY.read_text()
        return source[source.index(start):source.index(end)]

    def shell(self, body, **environment):
        definitions = self.source("FAILURES=0", "# Root-token")
        return subprocess.run(["bash", "-c", "set -euo pipefail\n" + definitions + body +
                               '\ntest "$FAILURES" -eq 0\n'],
                              env={**os.environ, **environment}, capture_output=True, text=True)

    def dependencies(self, state, helper_status="deployed"):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "kubectl"
            binary.write_text("#!" + sys.executable + '''
import json, os, sys
args = sys.argv[1:]
state = os.environ['JOB_STATE']
if 'jobs' in args:
    if state == 'api-error': raise SystemExit(1)
    if '-o' in args and args[args.index('-o')+1] == 'json':
        items = [] if state == 'collected' else [{
            'metadata': {'name': 'bootstrap-1', 'creationTimestamp': '2026-10-26T00:00:00Z'},
            'status': ({'succeeded': 1, 'failed': int(state == 'recovered')}
                       if state in ('complete', 'recovered') else {'failed': 1})}]
        print(json.dumps({'items': items}))
    elif state != 'collected': print('job.batch/bootstrap-1')
elif 'job.batch/bootstrap-1' in args or 'bootstrap-1' in args:
    print('1' if state == 'complete' else '')
elif 'statefulset' in args or 'deployment' in args:
    print('1')
elif 'svc' not in args:
    raise SystemExit(1)
''')
            binary.chmod(0o700)
            prelude = (f'K=("{binary}")\nQS_FULLNAME=permesi-quickstart\n'
                       'QS_RELEASE=permesi-quickstart\nVAULT_DEPLOY=permesi-quickstart-vault\n'
                       'PG_STATEFULSET=permesi-quickstart-postgresql\n'
                       f'HELPER_STATUS={helper_status}\n')
            section = self.source('section "Dependencies"', 'section "PostgreSQL')
            return self.shell(prelude + section, JOB_STATE=state)

    def test_collected_job_defers_to_durable_bootstrap_checks(self):
        result = self.dependencies("collected")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_job_and_api_errors_cannot_be_treated_as_collection(self):
        for state in ("failed", "api-error"):
            with self.subTest(state=state):
                result = self.dependencies(state)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_retained_successful_job_passes(self):
        result = self.dependencies("complete")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_completed_retry_is_not_mistaken_for_failed_job(self):
        result = self.dependencies("recovered")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_collected_job_does_not_hide_failed_helm_release(self):
        result = self.dependencies("collected", helper_status="failed")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_disabled_oidc_does_not_require_an_rsa_key(self):
        fixture = '''
OIDC_ENABLED=false
vroot() {
  local field="${3#-field=}" path="${4:-}"
  [[ "$*" != *oidc-signing* ]] || return 2
  case "$*" in
    *-field=type*totp) echo chacha20-poly1305 ;;
    *-field=type*genesis-signing) echo ed25519 ;;
    *-field=exportable*|*-field=allow_plaintext_backup*) echo false ;;
    *-field=auto_rotate_period*) echo 2592000 ;;
    *) return 2 ;;
  esac
}
'''
        section = self.source('for k in transit/permesi/keys/totp', 'seed_fp=')
        result = self.shell(fixture + section)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_disabled_oidc_requires_actual_signing_denial(self):
        policy = self.source('allow() {', 'allow "permesi reads')
        signing = self.source('allow "permesi reads', 'allow "permesi issues')
        fixture = '''
OIDC_ENABLED=false
PT=fixture
vas() {
  if [[ "$*" == *transit/permesi/sign/oidc-signing* && "$DENY_OIDC" == true ]]; then
    echo 'permission denied' >&2
    return 2
  fi
}
'''
        for denied in ("true", "false"):
            with self.subTest(signing_denied=denied):
                result = self.shell(fixture + policy + signing, DENY_OIDC=denied)
                self.assertEqual(result.returncode == 0, denied == "true", result.stdout)


if __name__ == "__main__":
    unittest.main()
