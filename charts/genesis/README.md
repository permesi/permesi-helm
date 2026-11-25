# genesis chart

Production-oriented Helm chart for the genesis edge admission service. Chart 0.6
and later deploy application 0.6 and later, which use OpenBao only: HashiCorp
Vault, the `vault:` values block and `secretsProvider` were removed, and rendering
fails if they are still set.

## What it exposes

This chart maps runtime configuration to the same environment variables used by
`genesis --help`, including:

- server mode (`GENESIS_PORT` or `GENESIS_SOCKET_PATH`)
- DB and TLS inputs (`GENESIS_DSN`, `GENESIS_TLS_PEM_BUNDLE`)
- OpenBao auth settings (`GENESIS_OPENBAO_*`), including the unusually named
  `GENESIS_TRANSIT_MOUNT` (set via `openbao.transitMount`)
- the Transit signing version (`GENESIS_ADMISSION_SIGNING_VERSION`, set via the
  required `admissionSigningVersion`)

## Secret handling

For sensitive fields you can use either:

- inline value (`*.value`) for local/dev
- Kubernetes Secret reference (`*.existingSecret` + `*.secretKey`) for production
- ExternalSecret (ESO) with an explicit `remoteKey`, which writes a Kubernetes
  Secret consumed by the Deployment automatically

This applies to:

- `database.dsn`
- `tls` (bundle Secret)
- `openbao.roleId`
- `openbao.secretId`
- `openbao.wrappedToken`

### ExternalSecret precedence

When `externalSecret.enabled` is `true`, the Deployment and the rendered
`ExternalSecret` resolve the same effective Secret name for each item:

1. an explicit `*.existingSecret` wins;
2. otherwise, when that item's `externalSecret.remoteKey` is set, the generated
   default target `<fullname>-db`, `<fullname>-tls`, or `<fullname>-openbao` is
   used;
3. otherwise the inline value is used (and no TLS bundle is mounted).

OpenBao's `role_id` and `secret_id` are always written into one Secret. When OpenBao
ESO is active both environment variables reference that same Secret, so
`openbao.roleId.existingSecret` and `openbao.secretId.existingSecret` must name the
same Secret, and `externalSecret.store` must be set whenever any
`externalSecret.remoteKey` is set.

## OpenBao URL

Genesis normalizes a base OpenBao URL to the standard AppRole login endpoint, so
both forms are accepted:

- base URL, e.g. `https://openbao.example.com:8200`
- full login endpoint, e.g. `https://openbao.example.com:8200/v1/auth/approle/login`

For the OpenBao Agent proxy, use the Unix socket path (the default).

`openbao.authMethod` defaults to `auto` (socket→Agent, TCP→AppRole).
Explicit `approle` requires TCP. Native `kubernetes` logs in with a projected
service-account token. Managed Agent requires `auto` and remains recommended when
PKI rendering is needed.

## Native Kubernetes OpenBao login

| Key | Default | Native-mode contract |
|---|---|---|
| `openbao.authMethod` | `auto` | `auto`, `approle`, `kubernetes` |
| `openbao.kubernetes.authMount` | `kubernetes` | relative mount, nested paths allowed; no `auth/` or `/v1/auth/` prefix |
| `openbao.kubernetes.role` | `""` | required service-specific OpenBao Kubernetes role |
| `openbao.kubernetes.tokenPath` | `/var/run/secrets/openbao-native/token` | normalized absolute file path in a dedicated non-root directory |
| `openbao.kubernetes.audience` | `openbao` | nonblank; must match the OpenBao role |
| `openbao.kubernetes.tokenExpirationSeconds` | `3600` | requested JWT lifetime, integer `600..86400` |

Example:

```yaml
openbao:
  url: https://openbao.example.com:8200
  authMethod: kubernetes
  agent:
    enabled: false
  kubernetes:
    role: genesis
serviceAccount:
  automount: false
tls:
  existingSecret: genesis-tls
```

Native mode requires a OpenBao HTTP(S) origin without credentials, application
path, query or fragment (trailing `/` allowed). It emits
`GENESIS_OPENBAO_AUTH_METHOD` and `GENESIS_OPENBAO_KUBERNETES_{AUTH_MOUNT,ROLE,TOKEN_PATH}`.
The application alone gets the read-only `0400` audience-scoped projected JWT.
No Agent/TokenReview RBAC is added; only OpenBao's reviewer needs TokenReview.
Native auth does not provision TLS/CA files: Secret/ESO and external CSI mounts
remain supported.

AppRole IDs, wrapped tokens, OpenBao ESO credential sources and conflicting
authentication `extraEnv` entries are rejected. Generic `extraEnvFrom` remains
supported but opaque to Helm; remove legacy AppRole credential variables from
imported Secrets/ConfigMaps. The application fails closed on native conflicts.
Reauthentication is restart-based: renewal failure drains/stops the process,
then the supervisor restart reads the current JWT and obtains a new token/DB
credentials. No hot token swap or fallback to AppRole is implemented.

## Admission metadata

Genesis signs admission tokens for Permesi. Set via `extraEnv` when you need to
override the defaults:

- `GENESIS_ADMISSION_ISS` (default `https://genesis.permesi.dev`) and
  `GENESIS_ADMISSION_AUD` (default `permesi`) must match Permesi's admission
  issuer/audience, or Permesi rejects the tokens.
- `GENESIS_IP_HEADER` (default `CF-Connecting-IP`) and
  `GENESIS_COUNTRY_HEADER` (default `CF-IPCountry`) are metadata only, not a
  trusted-proxy authentication boundary.

## Admission signing version

`admissionSigningVersion` is required: the Transit version of
`transit/genesis/keys/genesis-signing` that the core operator published to the
admission authority (`scripts/admission-authority` in the application repository).
Genesis signs only with that version, and Permesi verifies with the public keys it
reads from that authority in core OpenBao, not from Genesis. Publish a new version
before rolling Genesis to it; see the application's OpenTofu module README.

## Restart-safe authentication (HA)

A shared one-use SecretID or response-wrapping token is bootstrap-only, not
HA-safe: it can be consumed once, so replicas or later restarts fail. For
multi-replica deployments prefer the managed OpenBao Agent with per-pod auto-auth,
or provision AppRole credentials with sufficient uses and TTL. `openbao.secretId` and
`openbao.wrappedToken` are mutually exclusive.

## OpenBao Agent (managed sidecar, opt-in)

Set `openbao.agent.enabled: true` to render a chart-managed OpenBao Agent native
sidecar (Kubernetes ≥ 1.29 with `SidecarContainers`). It authenticates via
Kubernetes auth and renders the TLS bundle, so the backend needs no
AppRole/TLS Secrets. It reuses `openbao.url` (Unix socket) and `tls.pemBundlePath`
as destinations.

| Key | Default | Contract |
|---|---|---|
| `openbao.agent.enabled` | `false` | opt-in native sidecar |
| `openbao.agent.address` | `""` | required HTTP(S) OpenBao origin when enabled |
| `openbao.agent.image.{repository,tag,digest,pullPolicy}` | `docker.io/openbao/openbao`, `2.7.3`, pinned digest, `IfNotPresent` | must be an `*/openbao` repository with a digest |
| `openbao.agent.auth.{mount,role,audience,tokenExpirationSeconds}` | `kubernetes`, required role, `openbao`, `3600` | projected token audience must match the OpenBao role |
| `openbao.agent.ca.{existingConfigMap,key}` | `""` / `ca.crt` | public OpenBao CA; optional for public-root OpenBao |
| `openbao.agent.pki.{mount,role,commonName,dnsNames,ttl}` | `pki-int`, required role, required CN/SAN, `[]`, `24h` | service-specific PKI role |
| `openbao.agent.pki.renewalThreshold` | `0.8` | strict `0 < x < 1` |
| `openbao.agent.resources` | requests `{cpu: 20m, memory: 64Mi}`, limits `{cpu: 100m, memory: 128Mi}` | account for them in pod sizing |
| `openbao.agent.startupProbe.{periodSeconds,timeoutSeconds,failureThreshold}` | `5` / `5` / `120` | bounded startup budget |

When enabled, the chart requires a Unix-socket `openbao.url`, an Agent
`address`/`auth.role`, nonroot `runAsUser`/`runAsGroup` + `fsGroup`, and
`serviceAccount.automount=false`; in TCP-serving mode it also requires
`pki.role`/`pki.commonName` and at least one `pki.dnsNames`. It rejects
AppRole/wrapped-token/ESO OpenBao credentials and TLS Secret/ESO (when the Agent
renders the bundle), Vault Agent injector (`vault.hashicorp.com/agent-*`) annotations, duplicate
chart-owned env entries, and reserved volume names. `config.socketPath` omits the
inbound PKI template but keeps the OpenBao socket.

Managed socket/TLS files need absolute paths inside dedicated directories,
not directly under `/`. After path normalization, active mount directories must
be disjoint (neither equal nor ancestors/descendants), including `extraVolumeMounts`
and the Agent's `/openbao/config`, `/var/run/secrets/openbao-token`, `/tmp`, and
optional `/openbao/ca` mounts. Inactive TLS destinations do not reserve a mount;
a legacy TLS Secret mount still does.

The bundle contains one private key, the leaf, then the issuer chain read from the
PKI mount's `cert/ca_chain`. Import the complete issuer chain into OpenBao; the
Agent cannot reconstruct missing intermediates. A valid cached bundle may be reused
on Agent restart.

## Image digests

OpenBao workloads require pinned images: rendering fails without `image.digest`
(`sha256:<64 hex>`), and, with the Agent enabled, without
`openbao.agent.image.digest` on an `*/openbao` repository. The chart renders
`repository@digest`, so a tag change does not override a digest; update both
together. App release bumps set `image.digest` and do not change the Agent pin.

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
  admissionSigningVersion: 1
  openbao:
    url: https://openbao.example.com:8200
    roleId:
      existingSecret: genesis-openbao
      secretKey: role_id
    secretId:
      existingSecret: genesis-openbao
      secretKey: secret_id
```

## Validation rules

The chart enforces these invariants at render time:

- `service.enabled` must be `false` when `config.socketPath` is set.
- `openbao.secretId` and `openbao.wrappedToken` are mutually exclusive.
- In TCP `auto`/`approle` mode, `openbao.roleId` and one of `openbao.secretId` or
  `openbao.wrappedToken` must be configured. Native mode uses its Kubernetes role
  instead and rejects those AppRole credentials.
- `autoscaling.minReplicas` must not exceed `autoscaling.maxReplicas`.
- `externalSecret.store` must be set when any `externalSecret.remoteKey` is set.
- When OpenBao ESO is active, `openbao.roleId.existingSecret` and
  `openbao.secretId.existingSecret` must reference the same Secret.
- `admissionSigningVersion` must be set to a positive integer.
- The application image (and, when enabled, the OpenBao Agent image) must be
  pinned by digest.
- `extraEnv` must not set `PERMESI_OPENBAO_*`, `GENESIS_OPENBAO_*`,
  `GENESIS_ADMISSION_SIGNING_VERSION` or `PERMESI_ADMISSION_*`; use the chart values.
- The removed `vault:` block and `secretsProvider` are rejected rather than ignored.
