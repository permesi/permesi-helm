#!/usr/bin/env python3
"""Destructive real-cluster verifier regressions; use disposable qv-* namespaces.

Faults temporarily change ONLY the selected Vault database role, restore it in
finally, and revoke exactly the test's new leases. Concurrency runs the complete
shell wrapper in two existing independent full installations with the old fixed
ports occupied. Requires kubectl, python3, curl and QS_ADMISSION_BIN (or Cargo).
No credentials, raw Vault responses or child diagnostics are printed.
"""
import argparse
import errno
import json
from pathlib import Path
import socket
import subprocess
import sys


VERIFY = Path(__file__).resolve().parents[1] / 'verify.sh'


def require(ok, message):
    if not ok:
        raise RuntimeError(message)
    print('PASS: ' + message, flush=True)


def checked(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}); diagnostics withheld')
    return result.stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--context', required=True)
    p.add_argument('--namespace', required=True)
    p.add_argument('--release', required=True)
    p.add_argument('--helper-release', help='Explicit primary helper Helm release (umbrella: same as --release)')
    p.add_argument('--helper-fullname', help='Explicit primary dependency object prefix')
    p.add_argument('--faults', action='store_true', help='Use a deps-only installation, not one running concurrent verification')
    p.add_argument('--second-namespace')
    p.add_argument('--second-release')
    a = p.parse_args()
    require(a.namespace.startswith('qv-'), 'primary namespace is explicitly disposable qv-*')
    k = ['kubectl', '--context', a.context, '-n', a.namespace]
    helper_fullname = a.helper_fullname or a.helper_release or a.release + '-quickstart'
    root = k + ['exec', '-i', f'deploy/{helper_fullname}-vault', '-c', 'vault', '--', 'vault']
    verify = ['bash', str(VERIFY), '--context', a.context, '--namespace', a.namespace, '--release', a.release]
    if a.helper_release:
        verify += ['--helper-release', a.helper_release]
    if a.helper_fullname:
        verify += ['--helper-fullname', a.helper_fullname]
    if a.faults:
        path = 'database/roles/permesi'
        original = json.loads(checked(root + ['read', '-format=json', path]))['data']

        def write(config):
            checked(root + ['write', path, '-'], input=json.dumps(config))

        def leases():
            result = subprocess.run(root + ['list', '-format=json', 'sys/leases/lookup/database/creds/permesi'],
                                    text=True, capture_output=True)
            if result.returncode == 2 and result.stdout.strip() in ('', '{}'):
                return set()
            require(result.returncode == 0, 'read exact permesi lease inventory')
            return set(json.loads(result.stdout))

        for fault in ('missing-grant', 'failed-revocation'):
            before = leases()
            config = dict(original)
            before_tokens = set(json.loads(checked(root + ['list', '-format=json', 'auth/token/accessors'])))
            if fault == 'missing-grant':
                config['creation_statements'] = [statement for statement in original['creation_statements']
                                                 if not statement.lstrip().upper().startswith('GRANT ')]
            else:
                config['revocation_statements'] = ['SELECT verifier_nonexistent_revoke_function();']
            try:
                write(config)
                result = subprocess.run(verify + ['--deps-only'], text=True, capture_output=True)
                expected = ('FAIL: database/creds/permesi: exact issued identity' if fault == 'missing-grant'
                            else 'FAIL: database/creds/permesi: lease revocation failed')
                require(result.returncode != 0 and expected in result.stdout,
                        f'{fault} independently makes the real verifier fail for the intended assertion')
                require('verify.sh: ALL CHECKS PASSED' not in result.stdout,
                        f'{fault} cannot report all checks passed')
                if fault == 'failed-revocation':
                    require('FAIL: temporary' in result.stdout + result.stderr,
                            'failed revocation propagates temporary token/lease cleanup failure')
            finally:
                write(original)
                for lease in leases() - before:
                    checked(root + ['lease', 'revoke', '-sync', 'database/creds/permesi/' + lease])
                require(leases() == before, f'{fault}: original role config restored and test leases removed')
                after_tokens = set(json.loads(checked(root + ['list', '-format=json', 'auth/token/accessors'])))
                for accessor in after_tokens - before_tokens:
                    checked(root + ['token', 'revoke', '-accessor', accessor])
        checked(verify + ['--deps-only'])
        require(True, 'unmodified role configuration passes after both independent faults')

    if a.second_namespace:
        require(a.second_namespace.startswith('qv-') and a.second_namespace != a.namespace and bool(a.second_release),
                'concurrency uses two explicit independent disposable namespaces')
        listeners = []
        children = []
        try:
            for port in (18443, 19443, 18080, 19444):
                sock = socket.socket()
                try:
                    sock.bind(('127.0.0.1', port))
                    sock.listen()
                except OSError as error:
                    sock.close()
                    if error.errno != errno.EADDRINUSE:
                        raise
                    print(f'INFO: old port {port} already occupied; existing listener untouched', flush=True)
                else:
                    listeners.append(sock)
            second = ['bash', str(VERIFY), '--context', a.context, '--namespace', a.second_namespace,
                      '--release', a.second_release]
            # Files avoid pipe-buffer deadlock while both full verifiers run.
            import tempfile
            with tempfile.TemporaryFile(mode='w+') as one, tempfile.TemporaryFile(mode='w+') as two:
                for command, log in ((verify, one), (second, two)):
                    children.append(subprocess.Popen(command, stdout=log, stderr=log, text=True))
                statuses = [child.wait(timeout=300) for child in children]
                for status, log in zip(statuses, (one, two)):
                    log.seek(0)
                    output = log.read()
                    require(status == 0 and 'verify.sh: ALL CHECKS PASSED' in output and
                            'real OPAQUE signup/finish 201' in output,
                            'independent complete verifier succeeds with old fixed ports occupied')
            require(all(sock.fileno() >= 0 and sock.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN)
                        for sock in listeners), 'all test-owned old listeners remain open and untouched')
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
            for sock in listeners:
                sock.close()
    require(a.faults or bool(a.second_namespace), 'at least one real regression scenario selected')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'FAIL: {error}', file=sys.stderr, flush=True)
        raise SystemExit(1)
