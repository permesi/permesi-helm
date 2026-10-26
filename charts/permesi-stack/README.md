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

## Quickstart mode (upcoming)

A disposable one-`helm`-command install is planned (milestone M-UQ): an optional
`quickstart.enabled` dependency on the `permesi-quickstart` helper chart
(official `postgres:18` + dev-mode Vault + bootstrap jobs). It will require
`quickstart.enabled: true` **and** `quickstart.acknowledgeDevelopment: true`, and
rejects public exposure / production mode. It is explicitly disposable (in-memory
Vault, no backups/scheduler, no production support). Not yet available.
<!-- UNVERIFIED -->

## Image digest precedence

The umbrella-managed image blocks (`permesi.image`, `genesis.image`, `web.image`)
accept an optional `digest` (`sha256:<64 hex>`). When set, the chart renders
`repository@digest`; a tag change does not override it. Clear the digest to return
to `repository:tag`. <!-- UNVERIFIED: digest helper is M-DIG work. -->

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
