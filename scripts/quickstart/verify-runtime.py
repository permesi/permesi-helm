#!/usr/bin/env python3
"""Real quickstart proof. Called by verify.sh after dependency checks.

No mocks, TLS bypasses, Secret dumps or token/key diagnostics. --exercise-lifecycle
mutates only this quickstart's backend Deployments/pods; requires short leaf TTLs
(install.sh --pki-ttl 2m). Admission client is built with Cargo, or supplied with
QS_ADMISSION_BIN (use a musl build when running inside the Alpine hc container).
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import time


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        # Never echo command output: Vault/API failures can contain credentials.
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode})")
    return result.stdout.strip()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)
    print(f"PASS: {message}", flush=True)


def fullname(release, chart):
    return release if chart in release else f"{release}-{chart}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context', required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--release', default='permesi')
    parser.add_argument('--exercise-lifecycle', action='store_true')
    parser.add_argument('--rotation-timeout', type=int, default=240)
    a = parser.parse_args()
    k = ['kubectl', '--context', a.context, '-n', a.namespace]
    def kj(*args):
        return json.loads(run(k + list(args) + ['-o', 'json']))
    def ready(name):
        run(k + ['rollout', 'status', f'deploy/{name}', '--timeout=180s'])
        dep = kj('get', 'deploy', name)
        require(dep['status'].get('readyReplicas') == dep['spec']['replicas'] == 2,
                f'{name}: two Ready replicas')
    def pods(name):
        selector = kj('get', 'deploy', name)['spec']['selector']['matchLabels']
        labels = ','.join(f'{key}={value}' for key, value in selector.items())
        return kj('get', 'pods', '-l', labels)['items']
    def agent(pod, *args, invalid=False):
        cmd = k + ['exec', pod, '-c', 'vault-agent', '--', 'env',
                   f'VAULT_TOKEN={"invalid-operator-token" if invalid else ""}',
                   'vault', *args]
        return subprocess.run(cmd, text=True, capture_output=True)
    def proxy(pod, *args, invalid=False):
        # CLI global address belongs after the operation, before its arguments.
        return agent(pod, args[0], '-address=unix:///var/run/secrets/vaultproject.io/agent.sock',
                     *args[1:], invalid=invalid)

    ns = kj('get', 'namespace', a.namespace)
    require(ns['metadata'].get('labels', {}).get('pod-security.kubernetes.io/enforce') == 'restricted',
            f'{a.namespace}: Restricted PSA enforced')
    qs = a.release + '-quickstart'
    names = {'permesi': fullname(a.release, 'permesi'),
             'genesis': fullname(a.release + '-genesis', 'genesis')}
    web = fullname(a.release + '-web', 'web')
    selected = {}
    for svc, name in names.items():
        ready(name)
        for pod in pods(name):
            spec = pod['spec']
            app = next(c for c in spec['containers'] if c['name'] == svc)
            sidecar = next(c for c in spec['initContainers'] if c['name'] == 'vault-agent')
            require(sidecar.get('restartPolicy') == 'Always' and not spec.get('automountServiceAccountToken', True),
                    f"{pod['metadata']['name']}: native Agent; no automatic SA token")
            volumes = {v['name']: v for v in spec['volumes']}
            mounts = app.get('volumeMounts', [])
            require(not any('projected' in volumes[m['name']] or 'secret' in volumes[m['name']] for m in mounts),
                    f"{pod['metadata']['name']}: backend mounts no JWT/Secret volumes")
            require(not any(e['name'].endswith(('_ROLE_ID', '_SECRET_ID', '_WRAPPED_TOKEN')) for e in app.get('env', [])),
                    f"{pod['metadata']['name']}: no AppRole credentials")
            require(all(m.get('readOnly') for m in mounts), f"{pod['metadata']['name']}: backend artifact mounts read-only")
            pod_name = pod['metadata']['name']
            mode = run(k + ['exec', pod_name, '-c', 'vault-agent', '--', 'stat', '-c', '%a:%u:%g',
                            '/var/run/secrets/vaultproject.io/agent.sock'])
            require(mode == '600:10001:10001', f'{pod_name}: socket mode/owner 600:10001:10001')
            count = run(k + ['exec', pod_name, '-c', 'vault-agent', '--', 'sh', '-c',
                f"grep -c 'BEGIN .*PRIVATE KEY' /var/run/{svc}/tls/bundle.pem; grep -c 'BEGIN CERTIFICATE' /var/run/{svc}/tls/bundle.pem"])
            require(count.splitlines() == ['1', '3'], f'{pod_name}: bundle has one key + leaf/intermediate/root')
            result = proxy(pod_name, 'read', '-field=display_name', 'auth/token/lookup-self')
            require(result.returncode == 0 and f'kubernetes-{a.namespace}-' in result.stdout,
                    f'{pod_name}: tokenless authenticated proxy lookup')
            result = proxy(pod_name, 'read', 'auth/token/lookup-self', invalid=True)
            require(result.returncode != 0 and 'permission denied' in result.stderr,
                    f'{pod_name}: supplied invalid operator token is not overwritten')
        selected[svc] = pods(name)[0]

    for svc, pod in selected.items():
        other = 'genesis' if svc == 'permesi' else 'permesi'
        pod_name = pod['metadata']['name']
        denials = [('read', f'database/creds/{other}'),
                   ('write', f'pki-int/issue/{other}-runtime', f'common_name={names[other]}.{a.namespace}.svc')]
        if svc == 'permesi':
            denials.append(('write', 'transit/genesis/sign/genesis-signing', 'input=cXVpY2tzdGFydA=='))
        else:
            denials.extend([('read', 'secret/permesi/data/config'),
                            ('write', 'transit/permesi/sign/oidc-signing', 'input=cXVpY2tzdGFydA==')])
        for args in denials:
            result = proxy(pod_name, *args)
            require(result.returncode != 0 and 'permission denied' in result.stderr,
                    f'{svc} proxy denies {args[1]}')

    require(not any(s['type'] != 'helm.sh/release.v1' and s['metadata']['name'] != qs + '-bootstrap-credentials'
                    for s in kj('get', 'secrets')['items']), 'no application TLS/DB/AppRole Secrets')
    ready(web)
    binary = os.environ.get('QS_ADMISSION_BIN')
    if not binary:
        manifest = Path(__file__).parent / 'admission' / 'Cargo.toml'
        target = Path(os.environ.get('CARGO_TARGET_DIR', tempfile.gettempdir() + '/permesi-quickstart-admission'))
        run(['cargo', 'build', '--locked', '--release', '--manifest-path', str(manifest), '--target-dir', str(target)])
        binary = str(target / 'release' / 'quickstart-admission')

    forwards = []
    with tempfile.TemporaryDirectory(prefix='permesi-verify-') as tmp:
        tmp = Path(tmp)
        ca = tmp / 'root.pem'
        ca.write_text(run(k + ['exec', f'deploy/{qs}-vault', '-c', 'vault', '--', 'vault',
                              'read', '-field=certificate', 'pki-root/cert/ca']) + '\n')
        wrong_ca = tmp / 'wrong-ca.pem'
        wrong_ca.write_text(kj('get', 'configmap', 'kube-root-ca.crt')['data']['ca.crt'])
        tls = ssl.create_default_context(cafile=str(ca))
        def forward(target, port):
            proc = subprocess.Popen(k + ['port-forward', '--address', '127.0.0.1', target, f'{port}:8080'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            forwards.append(proc)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError('port-forward exited before becoming ready')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=1):
                        return proc
                except OSError:
                    time.sleep(.2)
            raise RuntimeError('port-forward never became ready')
        ports = {'permesi': 18443, 'genesis': 19443}
        def cert(svc, context=tls, hostname=None):
            with socket.create_connection(('127.0.0.1', ports[svc]), timeout=5) as sock:
                with context.wrap_socket(sock, server_hostname=hostname or ('api.localhost' if svc == 'permesi' else 'genesis.localhost')) as conn:
                    return conn.getpeercert()
        def https(svc, path):
            host = 'api.localhost' if svc == 'permesi' else 'genesis.localhost'
            port = ports[svc]
            return run(['curl', '--noproxy', '*', '--silent', '--show-error', '--fail', '--max-time', '20',
                        '--cacert', str(ca), '--resolve', f'{host}:{port}:127.0.0.1', f'https://{host}:{port}{path}'])
        def admission(expect_rejected=False, genesis_port=19443):
            env = dict(os.environ, QS_API_PORT='18443', QS_GENESIS_PORT=str(genesis_port))
            cmd = [binary, str(ca)] + (['--expect-rejected'] if expect_rejected else [])
            output = run(cmd, env=env)
            print(output, flush=True)
            if not expect_rejected:
                email = re.search(r'pending-account email=([a-z0-9-]+@example.test)', output)
                require(email is not None, 'OPAQUE signup completed with an identifiable pending account')
                email = email.group(1)
                query = ("SELECT (SELECT count(*) FROM users WHERE email='" + email + "' AND status='pending_verification')||','||"
                         "(SELECT count(*) FROM email_outbox WHERE to_email='" + email + "' AND payload_json IS NOT NULL)")
                counts = run(k + ['exec', qs + '-postgresql-0', '-c', 'postgresql', '--', 'psql', '-X', '-U', 'postgres', '-d', 'permesi', '-tAc', query])
                require(counts == '1,1', 'PostgreSQL contains pending OPAQUE user and verification outbox receipt (payload not printed)')
        def status_snapshot(pod):
            p = kj('get', 'pod', pod)
            statuses = p['status'].get('containerStatuses', []) + p['status'].get('initContainerStatuses', [])
            return p['metadata']['uid'], [(s['name'], s['restartCount']) for s in statuses]
        try:
            for svc, p in selected.items():
                forward('pod/' + p['metadata']['name'], ports[svc])
                for path in ['/live', '/ready'] + (['/paserk.json'] if svc == 'genesis' else []):
                    https(svc, path)
                    require(True, f'{svc} HTTPS {path}: trusted root and correct hostname')
                for context, host, label in [(ssl.create_default_context(cafile=str(wrong_ca)), None, 'wrong CA'),
                                             (tls, 'wrong.localhost', 'wrong hostname')]:
                    try:
                        cert(svc, context, host)
                    except ssl.SSLCertVerificationError:
                        require(True, f'{svc}: {label} rejected by TLS validation')
                    else:
                        raise RuntimeError(f'{svc}: {label} unexpectedly accepted')
            forward('svc/' + web, 18080)
            config = run(['curl', '--noproxy', '*', '-fsS', 'http://127.0.0.1:18080/config.js'])
            config = json.loads(config.split('=', 1)[1].strip().rstrip(';'))
            require(config == dict(api_base_url='https://api.localhost:8443', token_base_url='https://genesis.localhost:9443',
                                   client_id='00000000-0000-0000-0000-000000000000', opaque_server_id='api.localhost'),
                    'web /config.js contains intended browser URLs, client UUID and OPAQUE ID')
            admission()

            if a.exercise_lifecycle:
                # Correctly signed Genesis tokens with wrong claims must fail
                # admission. Clone a real Genesis pod (same Agent/DB/TLS), alter
                # exactly one public claim, and never route it through the main
                # Service. The production profile remains untouched.
                for env_name, wrong_value in [('GENESIS_ADMISSION_ISS', 'https://wrong.localhost'),
                                               ('GENESIS_ADMISSION_AUD', 'wrong-audience')]:
                    specimen = json.loads(json.dumps(selected['genesis']['spec']))
                    specimen.pop('nodeName', None)
                    app = next(c for c in specimen['containers'] if c['name'] == 'genesis')
                    next(e for e in app['env'] if e['name'] == env_name)['value'] = wrong_value
                    body = {'apiVersion': 'v1', 'kind': 'Pod',
                            'metadata': {'generateName': 'qs-claims-', 'namespace': a.namespace},
                            'spec': specimen}
                    test_pod = json.loads(run(k + ['create', '-f', '-', '-o', 'json'], input=json.dumps(body)))['metadata']['name']
                    claim_forward = None
                    try:
                        run(k + ['wait', '--for=condition=Ready', 'pod/' + test_pod, '--timeout=180s'])
                        claim_forward = forward('pod/' + test_pod, 19444)
                        admission(expect_rejected=True, genesis_port=19444)
                        require(True, f'{env_name}: real signed token rejected with only this claim changed')
                    finally:
                        if claim_forward:
                            claim_forward.terminate()
                            claim_forward.wait(timeout=5)
                        run(k + ['delete', 'pod', test_pod, '--wait=false'])
                # Same pod and fixed port-forward for the whole measurement:
                # load-balancing between two different leaf certs is NOT rotation.
                before = {svc: cert(svc)['serialNumber'] for svc in names}
                snapshots = {svc: status_snapshot(p['metadata']['name']) for svc, p in selected.items()}
                changed = set()
                deadline = time.monotonic() + a.rotation_timeout
                while time.monotonic() < deadline and len(changed) != len(names):
                    time.sleep(10)
                    for svc in names:
                        if svc in changed:
                            continue
                        https(svc, '/ready')
                        current = cert(svc)
                        if current['serialNumber'] != before[svc]:
                            require(snapshots[svc] == status_snapshot(selected[svc]['metadata']['name']),
                                    f"{svc}: served certificate rotated {before[svc]} -> {current['serialNumber']} without pod/container restart; expires {current['notAfter']}")
                            changed.add(svc)
                require(len(changed) == len(names), 'both backends hot-reloaded a new trusted leaf before rotation deadline')
                for svc, p in selected.items():
                    pod = p['metadata']['name']
                    baseline = kj('get', 'pod', pod)['status']['initContainerStatuses']
                    old = next(s['restartCount'] for s in baseline if s['name'] == 'vault-agent')
                    # Restart ONLY the Agent. Shared TLS/socket emptyDirs survive.
                    subprocess.run(k + ['exec', pod, '-c', 'vault-agent', '--', 'kill', '-TERM', '1'], capture_output=True)
                    deadline = time.monotonic() + 120
                    while time.monotonic() < deadline:
                        state = kj('get', 'pod', pod)['status']['initContainerStatuses']
                        s = next(s for s in state if s['name'] == 'vault-agent')
                        if s['restartCount'] > old and s.get('ready'):
                            result = proxy(pod, 'read', '-field=display_name', 'auth/token/lookup-self')
                            if result.returncode == 0:
                                https(svc, '/ready')
                                require(True, f'{svc}: Agent-only restart recovered authenticated socket and HTTPS readiness')
                                break
                        time.sleep(2)
                    else:
                        raise RuntimeError(f'{svc}: Agent-only restart did not recover')
                admission()
        finally:
            for proc in forwards:
                proc.terminate()
            for proc in forwards:
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

    if a.exercise_lifecycle:
        for svc, name in names.items():
            old = selected[svc]['metadata']['name']
            run(k + ['delete', 'pod', old, '--wait=true'])
            ready(name)
            require(all(p['metadata']['name'] != old for p in pods(name)), f'{svc}: deleted backend pod replaced and two replicas Ready')
            run(k + ['scale', 'deploy/' + name, '--replicas=3'])
            run(k + ['rollout', 'status', 'deploy/' + name, '--timeout=180s'])
            require(kj('get', 'deploy', name)['status'].get('readyReplicas') == 3, f'{svc}: scales 2 -> 3 with independent Kubernetes-auth identities')
            run(k + ['scale', 'deploy/' + name, '--replicas=2'])
            ready(name)
        # Re-run non-mutating proof against replacement pods, including actual
        # admission, not just Deployment status.
        cmd = ['python3', __file__, '--context', a.context, '--namespace', a.namespace, '--release', a.release]
        print(run(cmd, env=dict(os.environ, QS_ADMISSION_BIN=binary)), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'FAIL: {error}', flush=True)
        raise SystemExit(1)
