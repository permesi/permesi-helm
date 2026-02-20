# permesi-helm

Helm charts for the Permesi platform.

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
