#!/usr/bin/env python3
"""Destructive real-cluster verifier regressions; use disposable qv-* namespaces.

Faults temporarily change ONLY the selected Vault database role, restore it in
finally, and revoke exactly the test's new leases. Concurrency runs the complete
shell wrapper in two existing independent full installations with the old fixed
ports occupied. Bootstrap rotation mode creates and removes its own qv-rot-*
namespace and runs the actual deps-only installer against interrupted rotation
states. Requires kubectl, helm and python3; concurrency also needs curl and
QS_ADMISSION_BIN (or Cargo).
No credentials, raw Vault responses or child diagnostics are printed.
"""
import argparse
import base64
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


def bootstrap_rotation(a, k, root, helper_fullname):
    """Exercise persisted bootstrap cutpoints, never printing private state."""
    require(a.namespace.startswith('qv-rot-'), 'rotation namespace is explicitly disposable qv-rot-*')
    require(not (a.faults or a.second_namespace or a.helper_release or a.helper_fullname),
            'rotation mode owns a standalone default-named dependency release')
    require(not checked(k + ['get', 'namespace', a.namespace, '--ignore-not-found', '-o', 'name']).strip(),
            'rotation namespace does not already exist')
    checked(k + ['create', 'namespace', a.namespace])
    try:
        checked(k + ['label', 'namespace', a.namespace, 'pod-security.kubernetes.io/enforce=restricted'])
        install = ['bash', str(VERIFY.with_name('install.sh')), '--context', a.context,
                   '--namespace', a.namespace, '--release', a.release,
                   '--acknowledge-development', '--deps-only']
        if a.app_source:
            install += ['--app-source', a.app_source]

        def installer(succeeds=True, error=None):
            # Helm can wait until its deadline for a failed bootstrap Job. Keep
            # deliberate faults bounded, but require the real fault diagnostic.
            result = subprocess.run(install + ['--timeout', '120' if succeeds else '30'],
                                    text=True, capture_output=True, timeout=180)
            output = result.stdout + result.stderr
            if succeeds:
                require(result.returncode == 0 and 'bootstrap Job ' in output and ' succeeded' in output,
                        'actual deps-only installer completes bootstrap')
            else:
                require(result.returncode != 0 and error in output and 'install.sh: done.' not in output,
                        'actual installer fails at the injected rotation cutpoint')

        def sql(query):
            return checked(k + ['exec', '-i', f'statefulset/{helper_fullname}-postgresql',
                                '--', 'psql', '-X', '-qAt', '-U', 'postgres', '-d', 'postgres',
                                '-v', 'ON_ERROR_STOP=1'], input=query).strip()

        def hashes(suffix=''):
            rows = sql("SELECT rolname,rolpassword FROM pg_authid WHERE rolname IN "
                       f"('vault_permesi{suffix}','vault_genesis{suffix}') ORDER BY rolname")
            return dict(row.split('|', 1) for row in rows.splitlines())

        def marker_path(service):
            return 'bootstrap/manager-rotation/' + service

        def marker(service):
            return json.loads(checked(root + ['kv', 'get', '-format=json', '-mount=secret/permesi',
                                              marker_path(service)]))['data']['data']

        def put_marker(service, state, manager=None):
            checked(root + ['kv', 'put', '-mount=secret/permesi', marker_path(service), '-'],
                    input=json.dumps({'state': state, 'manager': manager or f'vault_{service}_manager'}))

        def complete(service):
            require(marker(service) == {'state': 'completed', 'manager': f'vault_{service}_manager'},
                    f'{service}: completion records the exact expected manager')

        def login(service):
            result = subprocess.run(
                k + ['exec', '-i', f'statefulset/{helper_fullname}-postgresql', '--', 'bash', '-c',
                     'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 '
                     '-U "$1" -d "$2" -tAc "SELECT current_user"',
                     'bash', f'vault_{service}_manager', service],
                input=passwords[service] + '\n', text=True, capture_output=True)
            if result.returncode:
                require('password authentication failed' in result.stderr,
                        f'{service}: rejected login is a password authentication failure')
            return result.returncode == 0

        def reset_manager(service):
            # Fixture only: recreate the exact successful-config/pre-rotation state.
            password = passwords[service].replace("'", "''")
            sql(f"SET standard_conforming_strings=on; ALTER ROLE vault_{service}_manager "
                f"WITH PASSWORD '{password}';")

        secret_name = helper_fullname + '-bootstrap-credentials'

        def set_root_token(token):
            checked(k + ['patch', 'secret', secret_name, '--type=merge', '-p',
                         json.dumps({'data': {'vault-root-token':
                                              base64.b64encode(token.encode()).decode()}})])

        def limited_install(path, capabilities, error='permission denied'):
            policy = 'bootstrap-rotation-regression'
            checked(root + ['policy', 'write', policy, '-'],
                    input='path "*" { capabilities = ["create","read","update","delete","list","sudo","patch"] }\n'
                          f'path "{path}" {{ capabilities = {json.dumps(capabilities)} }}\n')
            token = json.loads(checked(root + ['token', 'create', '-format=json', '-no-default-policy',
                                               '-policy=' + policy, '-ttl=10m']))['auth']['client_token']
            try:
                set_root_token(token)
                installer(False, error)
            finally:
                set_root_token(original_token)
                checked(root + ['write', 'auth/token/revoke', '-'], input=json.dumps({'token': token}))
                checked(root + ['policy', 'delete', policy])

        installer()
        secret = json.loads(checked(k + ['get', 'secret', secret_name, '-o', 'json']))['data']
        passwords = {service: base64.b64decode(secret[f'vault-{service}-password']).decode()
                     for service in ('permesi', 'genesis')}
        original_token = base64.b64decode(secret['vault-root-token']).decode()
        owners = hashes()
        for policy in ('permesi', 'genesis'):
            token = json.loads(checked(root + ['token', 'create', '-format=json', '-no-default-policy',
                                               '-policy=' + policy, '-ttl=5m']))['auth']['client_token']
            try:
                paths = ['secret/permesi/data/' + marker_path(service) for service in passwords]
                capabilities = json.loads(checked(root + ['write', '-format=json', 'sys/capabilities', '-'],
                                                   input=json.dumps({'token': token, 'paths': paths})))['data']
                require(all(capabilities[path] == ['deny'] for path in paths),
                        f'{policy}: workload cannot access either root-only rotation marker')
            finally:
                checked(root + ['write', 'auth/token/revoke', '-'], input=json.dumps({'token': token}))
        # Both valid configs exist with the bootstrap password. Cover missing and
        # pending markers separately; neither can establish completed rotation.
        for service in passwords:
            reset_manager(service)
            config = json.loads(checked(root + ['read', '-format=json', 'database/config/' + service]))['data']
            connection = dict(config['connection_details'])
            connection.update({key: config[key] for key in ('plugin_name', 'allowed_roles')})
            connection['password'] = passwords[service]
            checked(root + ['write', 'database/config/' + service, '-'], input=json.dumps(connection))
            if service == 'permesi':
                checked(root + ['kv', 'metadata', 'delete', '-mount=secret/permesi', marker_path(service)])
            else:
                put_marker(service, 'pending')
            require(login(service), f'{service}: cutpoint manager accepts the bootstrap password')
        installer()
        for service in passwords:
            require(not login(service), f'{service}: retry rotates away from the bootstrap password')
            complete(service)
        require(hashes() == owners, 'initial rotation retry preserves both schema-owner password hashes')

        # A stale completed marker must be reset BEFORE creating a new config.
        # Deny the actual rotation API: creation succeeds, but completion cannot.
        for service in passwords:
            reset_manager(service)
            checked(root + ['delete', 'database/config/' + service])
            limited_install('database/rotate-root/' + service, ['deny'])
            require(marker(service) == {'state': 'pending', 'manager': f'vault_{service}_manager'} and
                    login(service), f'{service}: failed new-config rotation leaves only pending state')
            installer()
            require(not login(service), f'{service}: recovery retries failed rotation')
            complete(service)

        # Rotation succeeds, then its completion write is forbidden. The next
        # installer must use Vault's current private password and rotate again.
        for service in passwords:
            manager = f'vault_{service}_manager'
            put_marker(service, 'pending')
            before = hashes('_manager')
            limited_install('secret/permesi/data/' + marker_path(service), ['read'])
            after = hashes('_manager')
            require(after[manager] != before[manager] and marker(service)['state'] == 'pending',
                    f'{service}: completion-write failure follows real rotation without false completion')
            installer()
            require(hashes('_manager')[manager] != after[manager] and not login(service),
                    f'{service}: retry after marker-write failure uses current Vault credentials')
            complete(service)

        before = hashes('_manager')
        limited_install('secret/permesi/data/' + marker_path('permesi'), ['deny'],
                        'cannot read initial rotation marker')
        require(hashes('_manager') == before, 'marker-read failure refuses bootstrap without rotating')
        limited_install('database/config/permesi', ['deny'], 'cannot inspect database/config/permesi')
        require(hashes('_manager') == before, 'config-read failure refuses to overwrite private credentials')
        checked(root + ['write', 'database/config/permesi', 'username=vault_permesi', 'verify_connection=false'])
        try:
            installer(False, 'legacy owner-as-manager')
            require(hashes('_manager') == before, 'legacy owner-as-manager config is still explicitly refused')
        finally:
            checked(root + ['write', 'database/config/permesi',
                            'username=vault_permesi_manager', 'verify_connection=true'])
        for state, manager in (('completed', 'unexpected_manager'), ('invalid', 'vault_permesi_manager')):
            put_marker('permesi', state, manager)
            try:
                installer(False, 'rotation marker')
                require(hashes('_manager') == before, 'corrupt completion state or identity fails without rotating')
            finally:
                put_marker('permesi', 'completed')
        installer()
        require(hashes('_manager') == before, 'normal completed-marker reinstall preserves private manager passwords')
        require(hashes() == owners, 'all retry and failure paths preserve both schema-owner passwords')
    finally:
        # The namespace was created by this invocation. Uninstall first so Helm
        # removes its exact hashed cluster-scoped TokenReview grants.
        release = a.release + '-quickstart'
        checked(['helm', '--kube-context', a.context, 'uninstall', release, '-n', a.namespace,
                 '--ignore-not-found', '--wait', '--timeout', '120s'])
        checked(k + ['delete', 'namespace', a.namespace, '--wait=true', '--timeout=120s'])
        require(True, 'owned rotation release, cluster grants and namespace removed')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--context', required=True)
    p.add_argument('--namespace', required=True)
    p.add_argument('--release', required=True)
    p.add_argument('--helper-release', help='Explicit primary helper Helm release (umbrella: same as --release)')
    p.add_argument('--helper-fullname', help='Explicit primary dependency object prefix')
    p.add_argument('--faults', action='store_true', help='Use a deps-only installation, not one running concurrent verification')
    p.add_argument('--bootstrap-rotation', action='store_true',
                   help='Create an absent qv-rot-* namespace, exercise real bootstrap retries, then remove it')
    p.add_argument('--app-source', help='Canonical application checkout for bootstrap rotation mode')
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
    if a.bootstrap_rotation:
        bootstrap_rotation(a, k, root, helper_fullname)
        return
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
