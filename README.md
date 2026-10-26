# permesi-helm

Helm charts for Permesi IAM, Genesis admission, and the web UI. Install components
separately or together with `charts/permesi-stack`.

## Choose your path

### Disposable development: one command

From this checkout, with Bash, Helm, kubectl and Python 3 on PATH:

```bash
bash scripts/quickstart/install.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --acknowledge-development
```

Use your explicit kube context; the installer does not change current-context.
It installs PostgreSQL, dev Vault, canonical SQL/Vault bootstrap, and two replicas
of each backend with Vault Agent. Images and SQL are pinned in
[`scripts/quickstart/lock.json`](scripts/quickstart/lock.json).

**Development only:** in-memory Vault and ephemeral PostgreSQL, no HA/backups or
pg_cron maintenance guarantee. Bootstrap-only administrator/root credentials live
in a retained Kubernetes Secret; application TLS private keys stay in pod memory.
See [install, verify, connect and teardown](docs/install-guide.md#disposable-quickstart).

Use an isolated development context. Current dev Vault startup logs can contain
root/unseal material; restrict `pods/log` access and downstream log retention.

### Helm-only umbrella quickstart

Use the fixed release/namespace profile documented in the
[umbrella quickstart section](charts/permesi-stack/README.md#quickstart-mode).
It requires both development acknowledgements and `--wait --wait-for-jobs`;
it is the same disposable dependency model, not a production installation.

### Production: external PostgreSQL + Vault

Use the [manual installation guide](docs/install-guide.md) and
[Vault Agent profile](docs/examples/vault-agent-stack.yaml). Agent supplies
Kubernetes authentication, the Unix proxy and PKI rendering without application
TLS/AppRole Secrets. PostgreSQL, Vault and the public HTTPS edge remain
operator-managed.

[Secret/AppRole/ESO alternatives](docs/examples/production-stack.yaml) remain
supported, but are not the recommended all-in-Vault path. Optional native
Kubernetes login needs an **unreleased rebuilt application image**; default
`0.4.3` images do not support its flags and it does not render PKI files.

## Requirements and chart references

- Helm 3.13+; tested application/dependency platform: **Linux/amd64**.
- Managed Agent uses native sidecars: **Kubernetes ≥1.29**, SidecarContainers
  enabled (stable in ≥1.33). The default Agent-disabled manifests do not impose
  that native-sidecar requirement.
- [Permesi](charts/permesi/README.md), [Genesis](charts/genesis/README.md),
  [web](charts/web/README.md), [umbrella](charts/permesi-stack/README.md).
- [Operations](docs/operations.md): auth, TLS/CA rotation, DB lease recovery,
  network policy, schema upgrades and release procedures.

For a released chart (check that its version contains the features you need):

```bash
helm upgrade --install permesi oci://ghcr.io/permesi/charts/permesi-stack \
  --version 0.4.4 --namespace permesi --create-namespace -f values.yaml
```

For integrated source features, rebuild local dependencies and use the manual
guide's source-install command; no new chart publication is implied.

## Validation and release automation

`Charts CI` keeps render/unit/Restricted-admission checks separate from the
`real-dependencies` job, which uses the actual quickstart install/verify driver.
The dev gate covers real HTTPS, admission/OPAQUE signup, leaf reload and restart;
it does not qualify production infrastructure or browser/WASM signup.
The independent `release-contracts` job runs the 13 parser/bump regression tests
with `python3 scripts/ci/test-release.py`.

`release-bump-pr.yml` validates nested per-service image digests and source
metadata through `scripts/ci/release-event.sh`. Tags never override a nonempty
`image.digest`. App and chart versions are independent; use
`scripts/bump-release.sh --chart-only X.Y.Z` for chart-only changes.
See [release contracts and local checks](docs/operations.md#10-release-and-image-identity).
Publishing/auto-release workflows remain repository automation; no push,
publication or GitHub-hosted execution is claimed by local validation.
