# genesis chart

Production-oriented Helm chart for the genesis edge admission service.

## What it exposes

This chart maps runtime configuration to the same environment variables used by
`genesis --help`, including:

- server mode (`GENESIS_PORT` or `GENESIS_SOCKET_PATH`)
- DB and TLS inputs (`GENESIS_DSN`, `GENESIS_TLS_PEM_BUNDLE`)
- Vault auth settings (`GENESIS_VAULT_*`), including the unusually named
  `GENESIS_TRANSIT_MOUNT` (set via `vault.transitMount`)

## Secret handling

For sensitive fields you can use either:

- inline value (`*.value`) for local/dev
- Kubernetes Secret reference (`*.existingSecret` + `*.secretKey`) for production
- ExternalSecret (ESO) with an explicit `remoteKey`, which writes a Kubernetes
  Secret consumed by the Deployment automatically

This applies to:

- `database.dsn`
- `tls` (bundle Secret)
- `vault.roleId`
- `vault.secretId`
- `vault.wrappedToken`

### ExternalSecret precedence

When `externalSecret.enabled` is `true`, the Deployment and the rendered
`ExternalSecret` resolve the same effective Secret name for each item:

1. an explicit `*.existingSecret` wins;
2. otherwise, when that item's `externalSecret.remoteKey` is set, the generated
   default target `<fullname>-db`, `<fullname>-tls`, or `<fullname>-vault` is
   used;
3. otherwise the inline value is used (and no TLS bundle is mounted).

Vault's `role_id` and `secret_id` are always written into one Secret. When vault
ESO is active both environment variables reference that same Secret, so
`vault.roleId.existingSecret` and `vault.secretId.existingSecret` must name the
same Secret, and `externalSecret.store` must be set whenever any
`externalSecret.remoteKey` is set.

## Vault URL

Genesis normalizes a base Vault URL to the standard AppRole login endpoint, so
both forms are accepted:

- base URL, e.g. `https://vault.example.com:8200`
- full login endpoint, e.g. `https://vault.example.com:8200/v1/auth/approle/login`

For the Vault Agent proxy, use the Unix socket path (the default).

## Admission metadata

Genesis signs admission tokens for Permesi. Set via `extraEnv` when you need to
override the defaults:

- `GENESIS_ADMISSION_ISS` (default `https://genesis.permesi.dev`) and
  `GENESIS_ADMISSION_AUD` (default `permesi`) must match Permesi's admission
  issuer/audience, or Permesi rejects the tokens.
- `GENESIS_IP_HEADER` (default `CF-Connecting-IP`) and
  `GENESIS_COUNTRY_HEADER` (default `CF-IPCountry`) are metadata only, not a
  trusted-proxy authentication boundary.

Genesis publishes public PASERK keys at `/paserk.json`; Permesi fetches this
endpoint over HTTPS to verify admission tokens. The TLS certificate SAN must
cover the Service DNS name Permesi uses for that endpoint.

## Restart-safe authentication (HA)

A shared one-use SecretID or response-wrapping token is bootstrap-only, not
HA-safe: it can be consumed once, so replicas or later restarts fail. For
multi-replica deployments use an externally managed Vault Agent auto-auth proxy
with a shared, ready socket (the default `vault.url`), or provision role IDs /
SecretIDs with sufficient uses and TTL. `vault.secretId` and
`vault.wrappedToken` are mutually exclusive.

## Vault Agent (managed sidecar, opt-in)

Set `vault.agent.enabled: true` to render a chart-managed Vault Agent native
sidecar (Kubernetes ≥ 1.29 with `SidecarContainers`). It authenticates via
Kubernetes auth and renders the TLS bundle, so the backend needs no
AppRole/TLS Secrets. It reuses `vault.url` (Unix socket) and `tls.pemBundlePath`
as destinations.

| Key | Default | Contract |
|---|---|---|
| `vault.agent.enabled` | `false` | opt-in native sidecar |
| `vault.agent.address` | `""` | required HTTPS Vault origin when enabled |
| `vault.agent.image.{repository,tag,digest,pullPolicy}` | `hashicorp/vault`, pinned patch | explicit tested patch, optional digest, `IfNotPresent` |
| `vault.agent.auth.{mount,role,audience,tokenExpirationSeconds}` | `kubernetes`, required role, `vault`, `3600` | projected token audience must match the Vault role |
| `vault.agent.ca.{existingConfigMap,key}` | `""` / `ca.crt` | public Vault CA; optional for public-root Vault |
| `vault.agent.pki.{mount,role,commonName,dnsNames,ttl}` | `pki-int`, required role, required CN/SAN, `[]`, `24h` | service-specific PKI role |
| `vault.agent.pki.renewalThreshold` | `0.8` | strict `0 < x < 1` |
| `vault.agent.resources` | small requests/limits | account for them in pod sizing |
| `vault.agent.startupProbe.{periodSeconds,timeoutSeconds,failureThreshold}` | `5` / `5` / `120` | bounded startup budget |

When enabled, the chart requires a Unix `vault.url`, an Agent address/role, and a
PKI role/SANs; requires `serviceAccount.automount=false`, nonroot UID/GID, and
compatible fsGroup; and rejects AppRole/wrapped/ESO Vault credentials and TLS
Secret/ESO (for the artifact the Agent now manages). `config.socketPath` omits the
inbound PKI template but keeps the Vault socket.

<!-- UNVERIFIED: exact keys/defaults and pinned Agent image tag confirmed by M-VA. -->

## Image digest precedence

Set `image.digest` (`sha256:<64 hex>`) to pin by digest: the chart renders
`repository@digest` and a tag change does not override it. Clear the digest to
return to `repository:tag`. <!-- UNVERIFIED: digest helper is M-DIG work. -->

## Graceful termination

The default `terminationGracePeriodSeconds` is 60 to cover the application's
request-drain budget; override the same key if your platform needs a different
value.

## Example (stack-style override)

```yaml
genesis:
  replicaCount: 2
  database:
    dsn:
      existingSecret: genesis-db
      secretKey: dsn
  tls:
    existingSecret: genesis-tls
    secretKey: bundle.pem
  vault:
    url: https://vault.example.com:8200
    roleId:
      existingSecret: genesis-vault
      secretKey: role_id
    secretId:
      existingSecret: genesis-vault
      secretKey: secret_id
```

## Validation rules

The chart enforces these invariants at render time:

- `service.enabled` must be `false` when `config.socketPath` is set.
- `vault.secretId` and `vault.wrappedToken` are mutually exclusive.
- When `vault.url` is HTTP(S), `vault.roleId` and one of `vault.secretId` or
  `vault.wrappedToken` must be configured.
- `autoscaling.minReplicas` must not exceed `autoscaling.maxReplicas`.
- `externalSecret.store` must be set when any `externalSecret.remoteKey` is set.
- When vault ESO is active, `vault.roleId.existingSecret` and
  `vault.secretId.existingSecret` must reference the same Secret.
