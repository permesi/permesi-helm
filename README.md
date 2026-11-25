# permesi-helm

Helm charts for Permesi IAM, Genesis admission, and the web UI. Install components
separately or together with `charts/permesi-stack`.

The charts deploy application 0.6 and later, which use OpenBao only. Use the
OpenBao shared profile, and add the isolated overlay when Genesis has its own
PostgreSQL and OpenBao endpoints. Both profiles use offline admission verification
from core-owned public keys. The release lock keeps the published 0.5.2 pins until
the 0.6.0 application release event replaces them.
See [shared values](docs/examples/openbao-shared.yaml),
[isolated overrides](docs/examples/openbao-isolated.yaml) and
[release qualification](docs/operations.md#release-and-sandbox-qualification).

## Breaking changes in chart 0.6

HashiCorp Vault support was removed; the charts cannot deploy 0.5 application
images. The `vault:` values block is now `openbao:`, `secretsProvider` is gone, and
the PASERK admission settings (`admission.paserkUrl`, `admission.paserkCaPath`,
`admission.paserkCa`, `openbao.agent.paserkCa`) were removed because 0.6 reads the
approved signing keys from the core OpenBao authority. Rendering fails, rather than
ignoring them, when these keys are still set. Agent resources use OpenBao names
(`openbao-agent` container, `openbao-agent-*` volumes, `<fullname>-openbao-agent`
ConfigMap, `<fullname>-openbao` ESO Secret), the default socket is
`/var/run/secrets/openbao/agent.sock`, the projected-token audience defaults to
`openbao` (match it in the OpenBao Kubernetes roles), and application and Agent
images must be pinned by digest. OpenBao itself is provisioned with the
application's OpenTofu module (`openbao/contrib/opentofu` in permesi/permesi).

## Choose your path

### Disposable development: one command

From this checkout, with Bash, Helm, kubectl and Python 3 on PATH:

```bash
bash scripts/quickstart/install.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --acknowledge-development
```

Use your explicit kube context; the installer does not change current-context.
It installs PostgreSQL, dev OpenBao, canonical SQL/OpenBao bootstrap, and two
replicas of each backend with OpenBao Agent. Images and SQL are pinned in
[`scripts/quickstart/lock.json`](scripts/quickstart/lock.json).

**Development only:** in-memory OpenBao and ephemeral PostgreSQL, no HA/backups or
pg_cron maintenance guarantee. Bootstrap-only administrator/root credentials live
in a retained Kubernetes Secret; application TLS private keys stay in pod memory.
See [install, verify, connect and teardown](docs/install-guide.md#disposable-quickstart).

Use an isolated development context. Canonical schema owners stay static;
separate OpenBao credential managers rotate without changing owner passwords.

### Helm-only umbrella quickstart

Use the fixed release/namespace profile documented in the
[umbrella quickstart section](charts/permesi-stack/README.md#quickstart-mode).
It requires both development acknowledgements and `--wait --wait-for-jobs`;
it is the same disposable dependency model, not a production installation.

### Production profile

Use the [manual installation guide](docs/install-guide.md) and the
[OpenBao Agent profile](docs/examples/openbao-shared.yaml). The Agent supplies
Kubernetes authentication, the Unix proxy and PKI rendering without application
TLS/AppRole Secrets. PostgreSQL, OpenBao and the public HTTPS edge remain
operator-managed.

[Secret/AppRole/ESO alternatives](docs/examples/production-stack.yaml) remain
supported, but are not the recommended path. Optional native Kubernetes login
(`openbao.authMethod: kubernetes`) does not render PKI files.

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
  --version 0.6.0 --namespace permesi --create-namespace -f values.yaml
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

The Permesi and Genesis charts reject unpinned application and Agent images;
web tag-fallback fixtures explicitly clear the digest so they remain independent
of release-pinned defaults. Separate assertions verify that a nonempty digest
takes precedence over a tag and malformed digests are rejected.

Consumer regressions additionally exercise real discovery-version values,
passthrough/header trust, generated installer values, effective helper settings
and verifier lifecycle decisions. Chart-testing uses Python 3.12 in both jobs
that install it, including its Yamale virtual environment. The real-dependency
job also tests custom dependency endpoints, collected/failed bootstrap Jobs,
failed Helm releases and OIDC enable/disable transitions against actual OpenBao
and PostgreSQL.

External GitHub Actions use upstream major-version tags so compatible fixes can
arrive without editing each workflow. Tool versions remain separate: Python stays
at 3.12 for chart testing, and the real-dependency Kind/node/kubectl pins stay explicit.
The Rust toolchain action uses `@v1` with `toolchain: stable`.
Chart-testing manages a `uv` virtual environment without pip; consumer-test
dependencies are installed with `uv pip` into that same environment.

For application changes newer than the published pins, use the
[candidate qualification procedure](docs/install-guide.md#qualifying-candidate-application-images).
It tests actual loaded image manifests and the exact application SQL revision
without changing release defaults or publishing images.

`release-bump-pr.yml` validates nested per-service image digests and source
metadata through `scripts/ci/release-event.sh`. Tags never override a nonempty
`image.digest`. App and chart versions are independent; use
`scripts/bump-release.sh --chart-only X.Y.Z` for chart-only changes.
See [release contracts and local checks](docs/operations.md#10-release-and-image-identity).
Publishing/auto-release workflows remain repository automation; no push,
publication or GitHub-hosted execution is claimed by local validation.
