# permesi-stack chart

Umbrella chart that installs platform components via subcharts:

- `permesi`
- `genesis`
- `web`

Each component can be enabled/disabled with:

- `permesi.enabled`
- `genesis.enabled`
- `web.enabled`

To configure runtime behavior, set nested values under each component key.

Example:

```yaml
permesi:
  database:
    dsn:
      existingSecret: permesi-db
      secretKey: dsn

genesis:
  database:
    dsn:
      existingSecret: genesis-db
      secretKey: dsn

web:
  runtimeConfig:
    apiBaseUrl: https://api.permesi.example.com
    tokenBaseUrl: https://genesis.permesi.example.com
    clientId: 00000000-0000-0000-0000-000000000000
    opaqueServerId: api.permesi.example.com
```

## Quickstart mode

The optional `permesi-quickstart` dependency is disabled by default:
`quickstart.enabled=false`, `quickstart.acknowledgeDevelopment=false`.
Enable both deliberately. `examples/quickstart.yaml` is the complete packaged
profile for **release `permesi`, namespace `permesi-quickstart`**, not a values
fragment that can be installed under arbitrary names:

```bash
kubectl --context kind-permesi-helm-test create namespace permesi-quickstart
kubectl --context kind-permesi-helm-test label namespace permesi-quickstart \
  pod-security.kubernetes.io/enforce=restricted
helm dependency build charts/permesi-stack
helm --kube-context kind-permesi-helm-test upgrade --install permesi charts/permesi-stack \
  --namespace permesi-quickstart -f charts/permesi-stack/examples/quickstart.yaml \
  --set quickstart.enabled=true --set quickstart.acknowledgeDevelopment=true \
  --wait --wait-for-jobs --timeout 12m
```

Use a namespace you own; if it already exists, inspect it rather than treating it
as disposable. Helm/kubectl need permission for the helper's cluster-scoped
reviewer RBAC. Kubernetes ≥1.29 with native sidecars and Linux/amd64 are the
tested requirements. The profile configures Agent, canonical SQL bootstrap,
service identities, DSNs, exact SANs, admission trust, outbox-only `example.test`
signup and public browser URLs. No sibling-value mutation is used.

The parent rejects enabled quickstart without a complete coherent application
profile, mismatched service/SA/Vault/DB/PKI/admission wiring and unsafe overrides.
Helper schema rejects unsupported persistence, production mode, replicas and
public infrastructure settings. Bootstrap Jobs are ordinary resources, not
post-install hooks; **`--wait --wait-for-jobs` is required** so failed SQL/archive/
Vault bootstrap fails the Helm operation. Do not infer success from web/dependency
readiness alone.

Other releases/namespaces require a complete explicit override of component and
helper names/SAs, namespace-qualified DSNs, Vault addresses, PKI CN/SANs and
PASERK URL. Changing only `-n` or the release name is not sufficient.
`tests/alternate-values.yaml` demonstrates release `atlas` in `uq-alt` with
custom Services and SAs; it is a source-tree test fixture, not packaged guidance.

### Browser, verification and teardown

For the fixed profile, `connect.sh` uses the same object names:

```bash
bash scripts/quickstart/connect.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --ca-out quickstart-ca.pem
```

It forwards web HTTP to `localhost:8080`, API HTTPS to `api.localhost:8443`,
Genesis HTTPS to `genesis.localhost:9443`. Resolve both `.localhost` names to
loopback and explicitly import only the exported public CA into a disposable
browser profile. No `-k`, silent trust change or automatic public HTTPS web edge.
See the [connection guide](../../docs/install-guide.md#verify-and-connect).

Use the runtime verifier directly (requires curl and Cargo or a compatible
`QS_ADMISSION_BIN`):

```bash
python3 scripts/quickstart/verify-runtime.py --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi
```

Do not substitute `verify.sh`: its bootstrap-Job selector expects the script's
separate helper release label `permesi-quickstart`, whereas umbrella resources
belong to Helm release `permesi`. The direct runtime verifier was exercised in
the M-UQ report before/after upgrades; the complete shell wrapper was not.

This is **development only**: single ephemeral PostgreSQL and in-memory HTTP dev
Vault, no HA/backups/pg_cron/production support. Bootstrap administrator/owner/root
credentials use a retained, narrowly mounted Kubernetes Secret; application
TLS/DB/AppRole secrets are not synchronized to Kubernetes. Current Vault dev
startup logs can contain credentials: restrict log readers and sinks. Lost Vault
with retained databases is not repaired by generating replacement seeds.
Outbox signup is not delivered email, verified login, OIDC E2E or browser/WASM
qualification. See [current quickstart qualifications](../../docs/operations.md#11-quickstart-qualification-and-known-boundaries).

Stop owned forwards, then remove **only your disposable installation**:

```bash
helm --kube-context kind-permesi-helm-test uninstall permesi -n permesi-quickstart
kubectl --context kind-permesi-helm-test delete namespace permesi-quickstart
```

Uninstall first to remove cluster-scoped reviewer RBAC; namespace deletion removes
the retained bootstrap Secret and ephemeral state. Remove imported development CA
trust from the browser when finished. Never delete an unrelated namespace/cluster.

## Image digest precedence

The umbrella-managed image blocks (`permesi.image`, `genesis.image`, `web.image`)
accept an optional `digest` (`sha256:<64 hex>`). When set, the chart renders
`repository@digest`; a tag change does not override it. Clear the digest to return
to `repository:tag`. Backend `vault.agent.image.digest` is pinned independently.
See [release procedures](../../docs/operations.md#10-release-and-image-identity)
for digest clearing and independent app/chart version handling.

## Production profile and runbook

A tested, internally consistent production profile is provided at
[`docs/examples/production-stack.yaml`](../../docs/examples/production-stack.yaml);
see [`docs/operations.md`](../../docs/operations.md) for the matching operational
runbook (Vault, TLS, split trust, HA, NetworkPolicy, upgrades). A Vault Agent
profile (Kubernetes auth + PKI, no TLS/AppRole Secrets) is at
[`docs/examples/vault-agent-stack.yaml`](../../docs/examples/vault-agent-stack.yaml),
with the step-by-step manual guide at
[`docs/install-guide.md`](../../docs/install-guide.md).

## Release-name-dependent Genesis DNS

The Genesis `Service` and `Deployment` names include the release name: a release
named `permesi` in namespace `permesi` creates `permesi-genesis`, not `genesis`
(`charts/genesis/templates/_helpers.tpl`, `charts/genesis/templates/service.yaml`).
The umbrella chart supplies no `fullnameOverride`, so Permesi's admission keyset
URL must use that generated name:

```yaml
permesi:
  admission:
    paserkUrl: https://permesi-genesis.permesi.svc.cluster.local:8080/paserk.json
```

In general, the endpoint is
`https://<release>-genesis.<namespace>.svc.cluster.local:<genesis.service.port>/paserk.json`.
If you override `genesis.fullnameOverride` or `genesis.nameOverride`, adjust the
host to match the generated Service name (and its TLS certificate SAN). The
chart's install `NOTES` print the actual URL and warn when
`permesi.admission.paserkUrl` does not match it; an external or separately managed
Genesis URL is still valid.
