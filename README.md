# permesi-helm

Helm charts for the Permesi platform.

## Choose your path

Three ways to run Permesi on Kubernetes:

- **Quickstart (disposable dev, one command).** `scripts/quickstart/install.sh`
  brings up a throwaway cluster-local PostgreSQL and dev-mode Vault, bootstraps
  them, then installs the stack in Vault Agent mode. Explicitly disposable:
  in-memory Vault, no backups, no scheduler, no production support.
  See `docs/install-guide.md` and the script help.
  <!-- UNVERIFIED: install.sh/verify.sh/connect.sh command contract pending M-QS -->
- **Helm-only quickstart (umbrella).** The `permesi-stack` chart gains an
  optional `quickstart.enabled` dependency (milestone M-UQ) that reuses the same
  helper chart for a one-`helm`-command disposable install. Not yet available.
  <!-- UNVERIFIED -->
- **Production (external PostgreSQL + Vault).** Operate external PostgreSQL and
  Vault. Use the chart-managed **Vault Agent** (Kubernetes auth + PKI certificate
  rendering) — recommended. The legacy paths (AppRole Secrets, External Secrets
  Operator) remain supported. See `docs/install-guide.md` (step-by-step manual
  guide), `docs/examples/vault-agent-stack.yaml` (Agent profile), and
  `docs/operations.md` (runbook).

## Charts

- `charts/permesi`: production-oriented IAM service chart (Deployment/Service/Ingress/HPA/PDB/NetworkPolicy, schema validation, secret wiring)
- `charts/genesis`: production-oriented edge admission chart with the same operational patterns
- `charts/web`: production-oriented web UI chart with runtime `config.js` injection from values or an external ConfigMap
- `charts/permesi-stack`: umbrella chart to install `permesi`, `genesis`, and `web` together

See:

- `charts/permesi/README.md`
- `charts/genesis/README.md`
- `charts/web/README.md`
- `charts/permesi-stack/README.md`
- `docs/examples/production-stack.yaml`: a tested, internally consistent production profile
- `docs/examples/vault-agent-stack.yaml`: production profile using the managed Vault Agent (Kubernetes auth + PKI), no TLS/AppRole Secrets
- `docs/install-guide.md`: step-by-step manual installation guide (production and disposable quickstart)
- `docs/operations.md`: operational runbook (Vault, TLS, HA, NetworkPolicy, upgrades)

## Install

Prerequisites:

- Kubernetes cluster
- Helm 3.13+

### Install from OCI (recommended)

Install the full stack:

```bash
helm upgrade --install permesi \
  oci://ghcr.io/permesi/charts/permesi-stack \
  --version 0.4.4 \
  --namespace permesi \
  --create-namespace \
  -f values.yaml
```

Install single components:

```bash
helm upgrade --install permesi-api oci://ghcr.io/permesi/charts/permesi --version 0.4.4 -n permesi --create-namespace -f permesi-values.yaml
helm upgrade --install permesi-genesis oci://ghcr.io/permesi/charts/genesis --version 0.4.4 -n permesi --create-namespace -f genesis-values.yaml
helm upgrade --install permesi-web oci://ghcr.io/permesi/charts/web --version 0.4.4 -n permesi --create-namespace -f web-values.yaml
```

### Install from source checkout (local/dev)

```bash
git clone https://github.com/permesi/permesi-helm.git
cd permesi-helm/charts/permesi-stack
helm dependency build
helm upgrade --install permesi . -n permesi --create-namespace -f values.yaml
```

### Minimal `values.yaml` example

```yaml
permesi:
  database:
    dsn:
      existingSecret: permesi-db
      secretKey: dsn
  tls:
    existingSecret: permesi-tls
    secretKey: bundle.pem
  vault:
    # Permesi POSTs to this URL verbatim for AppRole login, so it must be the
    # full login endpoint (not just the origin).
    url: https://vault.example.com:8200/v1/auth/approle/login
    roleId:
      existingSecret: permesi-vault
      secretKey: role_id
    secretId:
      existingSecret: permesi-vault
      secretKey: secret_id

genesis:
  database:
    dsn:
      existingSecret: genesis-db
      secretKey: dsn
  tls:
    existingSecret: genesis-tls
    secretKey: bundle.pem
  vault:
    # Genesis accepts a base URL (or the full login endpoint) and normalizes it.
    url: https://vault.example.com:8200
    roleId:
      existingSecret: genesis-vault
      secretKey: role_id
    secretId:
      existingSecret: genesis-vault
      secretKey: secret_id

web:
  runtimeConfig:
    apiBaseUrl: https://api.permesi.example.com
    tokenBaseUrl: https://genesis.permesi.example.com
    clientId: 00000000-0000-0000-0000-000000000000
    opaqueServerId: api.permesi.example.com
```

## Release Sync Automation

This repository includes a workflow that opens a PR whenever `permesi` publishes a release.

- Trigger: `repository_dispatch` with event type `permesi-release`
- Payload field used: `client_payload.version`
- Manual fallback: `workflow_dispatch` with a `version` input

Workflow file: `.github/workflows/release-bump-pr.yml`
Script used for updates: `scripts/bump-release.sh`

### Files bumped by automation

- `charts/permesi/Chart.yaml`
- `charts/genesis/Chart.yaml`
- `charts/web/Chart.yaml`
- `charts/permesi-stack/Chart.yaml`
- `charts/permesi/values.yaml` (`image.tag`)
- `charts/genesis/values.yaml` (`image.tag`)
- `charts/web/values.yaml` (`image.tag`)
- `charts/permesi-stack/values.yaml` (image tags marked with `# managed-by-release-bot`)

## CI Validation

Chart changes are validated with Chart Testing:

- Workflow: `.github/workflows/charts-ci.yml`
- `ct lint` validates chart structure and Helm lint rules.
- `ct install` runs install checks against a temporary Kind cluster.

Configuration is in `.ct.yaml`.

## OCI Publish

Charts are published to GHCR OCI:

- Workflow: `.github/workflows/publish-charts.yml`
- Target registry path: `oci://ghcr.io/permesi/charts`
- Trigger: GitHub Release publish in this repo, or manual dispatch with `version`.

The publish workflow validates each chart version matches the release version before pushing.

## Auto Release

Releases can be automated after CI success on `main`:

- Workflow: `.github/workflows/auto-release.yml`
- Trigger: `workflow_run` after `Charts CI` completes successfully for `push` events on `main`
- Behavior:
  - Reads chart version from `charts/permesi-stack/Chart.yaml`
  - Validates all chart versions match
  - Creates release tag `v<version>` if it does not already exist
  - Triggers `.github/workflows/publish-charts.yml` via the `release.published` event
