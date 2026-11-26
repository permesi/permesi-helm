# permesi-helm

Helm charts for Permesi IAM, Genesis admission and the web UI. Install the
components separately or together with `charts/permesi-stack`.

| Chart | Deploys |
| --- | --- |
| [`permesi`](charts/permesi/README.md) | Core IAM and OIDC service |
| [`genesis`](charts/genesis/README.md) | Edge admission token service |
| [`web`](charts/web/README.md) | Web UI |
| [`permesi-stack`](charts/permesi-stack/README.md) | All three, with an optional disposable quickstart |

The backends take their secrets from OpenBao: database credentials, TLS
certificates and the admission keys. Permesi verifies admission tokens offline,
against public keys held in the core OpenBao. PostgreSQL, OpenBao and the public
HTTPS edge are operated outside the charts. Provision OpenBao with the
application's OpenTofu module (`openbao/contrib/opentofu` in permesi/permesi).

## Requirements

- Helm 3.13 or later.
- Linux/amd64 nodes. The application and dependency images are tested on that
  platform only.
- Kubernetes 1.29 or later with SidecarContainers enabled (stable from 1.33) when
  the chart manages the OpenBao Agent, which runs as a native sidecar. Without
  the managed Agent there is no such requirement.
- Application and OpenBao Agent images pinned by digest. The Permesi and Genesis
  charts refuse to render otherwise, and a digest always takes precedence over a
  tag.

## Install

### Disposable development cluster

From this checkout, with Bash, Helm, kubectl and Python 3 on `PATH`:

```bash
bash scripts/quickstart/install.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --acknowledge-development
```

Name the kube context explicitly; the installer does not change the current
one. It installs PostgreSQL, a development OpenBao, the SQL and OpenBao
bootstrap, and two replicas of each backend with an OpenBao Agent. Images and
SQL are pinned in [`scripts/quickstart/lock.json`](scripts/quickstart/lock.json).

This is for development only. OpenBao runs in memory and PostgreSQL is
ephemeral, with no high availability or backups. The bootstrap administrator
and root credentials sit in a retained Kubernetes Secret. See
[install, verify, connect and teardown](docs/install-guide.md#disposable-quickstart).

The same disposable setup is available through Helm alone, as the umbrella
chart's [quickstart mode](charts/permesi-stack/README.md#quickstart-mode).

### Production

Follow the [installation guide](docs/install-guide.md) and start from one of the
example value files:

- [`openbao-shared.yaml`](docs/examples/openbao-shared.yaml): both backends use
  one PostgreSQL and one OpenBao.
- [`openbao-isolated.yaml`](docs/examples/openbao-isolated.yaml): an overlay for
  when Genesis has its own PostgreSQL and OpenBao.
- [`production-stack.yaml`](docs/examples/production-stack.yaml): Secret, AppRole
  and External Secrets alternatives to the Agent. Supported, not recommended.

In the recommended profile the chart runs an OpenBao Agent beside each backend.
The Agent logs in with the pod's Kubernetes identity, proxies OpenBao on a Unix
socket (`/var/run/secrets/openbao/agent.sock` by default) and renders the TLS
bundle into memory, so no application TLS key or AppRole credential is stored in
a Kubernetes Secret. The projected token's audience defaults to `openbao` and has
to match the OpenBao Kubernetes roles. The backends can also log in to OpenBao
themselves (`openbao.authMethod: kubernetes`); that mode does not render the TLS
files.

Install a published chart with:

```bash
helm upgrade --install permesi oci://ghcr.io/permesi/charts/permesi-stack \
  --version 0.6.0 --namespace permesi --create-namespace -f values.yaml
```

Day-two procedures are in the [operations runbook](docs/operations.md):
authentication, TLS and CA rotation, database lease recovery, network policy,
schema upgrades and releases.

## Development

Run the checks that need no cluster before pushing:

```bash
for chart in charts/* scripts/quickstart/chart; do helm unittest "$chart"; done
python3 scripts/ci/check-release-fixture.py
python3 -m unittest discover -s scripts/ci -p 'test_*.py'
python3 scripts/ci/test-release.py
python3 -m unittest discover -s scripts/quickstart/tests -p 'test_*.py'
python3 scripts/ci/test-chart-contracts.py
```

They need Helm with the `helm-unittest` plugin, and Python 3.12 with PyYAML.

`Charts CI` runs the same checks, lints and installs every chart with
chart-testing, and installs the quickstart against a real PostgreSQL and
OpenBao in Kind. That last job covers HTTPS, admission and OPAQUE signup,
certificate reload and restarts. It does not cover production infrastructure
or signup through the browser.

`Candidate containment` runs on every push to `sandbox`. It takes the
application images built from the application's `sandbox` branch and runs the
containment suite against them in two profiles, shared and isolated. See
[release and sandbox qualification](docs/operations.md#release-and-sandbox-qualification).
To qualify application changes by hand, use the
[candidate qualification procedure](docs/install-guide.md#qualifying-candidate-application-images).

## Releases

Application and chart versions are independent. An application release
dispatches `Release Bump PR`, which verifies the three image digests and their
source attestations, then opens a pull request that updates the chart versions,
the image pins and `scripts/quickstart/lock.json` together. Once that change is
on `main` and `Charts CI` passes, `Auto Release` creates the release and
`Publish Charts` pushes the charts to `oci://ghcr.io/permesi/charts`.

For a change to the charts alone:

```bash
scripts/bump-release.sh --chart-only X.Y.Z
```

See [release and image identity](docs/operations.md#10-release-and-image-identity).
