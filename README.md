# permesi-helm
Helm charts for Permesi.

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
- `charts/permesi-stack/values.yaml` (image tags marked with `# managed-by-release-bot`)

## CI Validation
Chart changes are validated with Chart Testing:

- Workflow: `.github/workflows/charts-ci.yml`
- `ct lint` validates chart structure and Helm lint rules.
- `ct install` runs install checks against a temporary Kind cluster.

Configuration is in `.ct.yaml`.

## OCI Publish
Charts can be published to GHCR OCI:

- Workflow: `.github/workflows/publish-charts.yml`
- Target registry path: `oci://ghcr.io/permesi/charts`
- Trigger: GitHub Release publish in this repo, or manual dispatch with `version`.

The publish workflow validates each chart version matches the release version before pushing.

## Chart Layout
- `charts/permesi`: core IAM chart metadata (placeholder)
- `charts/genesis`: edge admission chart metadata (placeholder)
- `charts/web`: frontend chart metadata (placeholder)
- `charts/permesi-stack`: umbrella chart with enable/disable toggles per component

These are initial scaffolds so automation and release flow can be wired first.
