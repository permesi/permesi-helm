# permesi chart

Production-oriented Helm chart for the permesi IAM service. The service takes
its secrets from OpenBao.

## What it exposes

This chart maps runtime configuration to the same environment variables used by
`permesi --help`, including:

- server mode (`PERMESI_PORT` or `PERMESI_SOCKET_PATH`)
- DB and TLS inputs (`PERMESI_DSN`, `PERMESI_TLS_PEM_BUNDLE`)
- admission verifier settings (`PERMESI_ADMISSION_*`)
- OpenBao auth and KV paths (`PERMESI_OPENBAO_*`)
- auth/session/outbox/OPAQUE/admin settings

## Secret handling

For sensitive fields you can use either:

- inline value (`*.value`) for local/dev
- Kubernetes Secret reference (`*.existingSecret` + `*.secretKey`) for production
- ExternalSecret (ESO) synthesis by enabling `externalSecret` and setting the
  item's `externalSecret.remoteKey`

This applies to `database.dsn`, `tls` and `openbao` (role_id/secret_id).

### ExternalSecret precedence

Each source resolves to one effective Secret name used consistently by both the
Deployment and any generated ExternalSecret:

1. An explicit `*.existingSecret` wins.
2. Otherwise, when `externalSecret.enabled` is true and that item's
   `externalSecret.remoteKey` is set, the chart uses the generated default
   target name (`<fullname>-db`, `<fullname>-tls`, `<fullname>-openbao`).
3. Otherwise the value is used inline / the volume is not mounted, as before.

OpenBao ESO writes `role_id` and `secret_id` into a single Secret; the Deployment
reads both from that same Secret. Setting `openbao.roleId.existingSecret` and
`openbao.secretId.existingSecret` to different names while OpenBao ESO is active
fails rendering. Any `externalSecret.remoteKey` also requires a non-empty
`externalSecret.store`.

## OpenBao authentication

`openbao.authMethod: auto` (default) preserves socket→Agent and TCP→AppRole.
`approle` explicitly requires TCP. `kubernetes` selects native application login
and is mutually exclusive with managed Agent (which requires `auto`).

For direct AppRole, an origin URL (empty path or `/`, no query) is completed to
`/v1/auth/approle/login`; any other path, such as a proxy prefix or a custom auth
mount, is used verbatim:

```yaml
openbao:
  url: https://openbao.example.com:8200/v1/auth/approle/login
```

Agent socket mode is passed through unchanged.

A static one-use SecretID or a response-wrapped token is bootstrap-only: the
application logs in on every startup, so a shared one-use credential cannot
survive replicas or restarts. For multi-replica, restart-safe deployments prefer
the OpenBao Agent socket (auto-auth) or provision a SecretID with suitable
`secret_id_num_uses`/TTL rather than sharing a one-use credential.

## Native Kubernetes OpenBao login

`openbao.authMethod: kubernetes` logs the application in with a projected
service-account token. Native login does not supply PKI or inbound TLS; the Agent
remains recommended when certificate rendering is required.

| Key | Default | Native-mode contract |
|---|---|---|
| `openbao.authMethod` | `auto` | `auto`, `approle`, `kubernetes` |
| `openbao.kubernetes.authMount` | `kubernetes` | relative mount, nested paths allowed; no `auth/` or `/v1/auth/` prefix |
| `openbao.kubernetes.role` | `""` | required service-specific OpenBao Kubernetes role |
| `openbao.kubernetes.tokenPath` | `/var/run/secrets/openbao-native/token` | normalized absolute file path in a dedicated non-root directory |
| `openbao.kubernetes.audience` | `openbao` | nonblank; must match the OpenBao role |
| `openbao.kubernetes.tokenExpirationSeconds` | `3600` | requested JWT lifetime, integer `600..86400` |

```yaml
openbao:
  url: https://openbao.example.com:8200
  authMethod: kubernetes
  agent:
    enabled: false
  kubernetes:
    role: permesi
serviceAccount:
  automount: false
tls:
  existingSecret: permesi-tls
```

Native mode requires an OpenBao HTTP(S) origin without credentials, path (except
`/`), query or fragment. It emits `PERMESI_OPENBAO_AUTH_METHOD` and
`PERMESI_OPENBAO_KUBERNETES_{AUTH_MOUNT,ROLE,TOKEN_PATH}`. A `0400` audience-scoped
JWT projection is mounted read-only into the application only. No Agent or
TokenReview RBAC is created; only OpenBao's reviewer identity needs TokenReview.
Supply the TLS bundle separately through Secret/ESO or external volume mounts.

Inline/Secret AppRole credentials, wrapped tokens, OpenBao ESO credential sources
and conflicting authentication `extraEnv` entries are rejected. `extraEnvFrom`
remains supported: Helm cannot inspect external contents; operators must keep
AppRole credential variables out of it. The application fails closed on
native-mode conflicts. Token renewal failure stops/drains the service; a
supervisor restart re-reads the JWT, logs in and acquires new DB credentials.
There is no hot token swap or auth-mode fallback.

## OpenBao Agent (managed sidecar, opt-in)

Set `openbao.agent.enabled: true` to render a chart-managed OpenBao Agent native
sidecar (Kubernetes ≥ 1.29 with `SidecarContainers`). It authenticates via
Kubernetes auth and renders the TLS bundle, so the backend needs no AppRole or TLS
Secrets. It reuses `openbao.url` (Unix socket) and `tls.pemBundlePath` as
destinations.

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
AppRole/wrapped-token/ESO OpenBao credentials, TLS Secret/ESO (when the Agent
renders the bundle), Vault Agent injector (`vault.hashicorp.com/agent-*`)
annotations, duplicate chart-owned env entries, and reserved volume names.
`config.socketPath` omits the inbound PKI template but keeps the OpenBao socket.

Managed socket and TLS files need absolute paths inside dedicated directories,
not directly under `/`. After path normalization, active mount directories must
be disjoint (neither equal nor ancestors/descendants), including `extraVolumeMounts`
and the Agent's `/openbao/config`, `/var/run/secrets/openbao-token`, `/tmp`, and
optional `/openbao/ca` mounts. An inactive TLS destination does not reserve a
mount; a legacy Secret mount still does.

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

## Termination grace

`terminationGracePeriodSeconds` defaults to 60 to cover the application's
bounded shutdown budget: up to 30s of request drain, 10s of email-worker
shutdown, 5s of database-pool close, plus telemetry flush.

## Example (stack-style override)

```yaml
permesi:
  replicaCount: 2
  database:
    dsn:
      existingSecret: permesi-db
      secretKey: dsn
  tls:
    existingSecret: permesi-tls
    secretKey: bundle.pem
  admission:
    issuer: https://genesis.permesi.example.com
    audience: permesi
  openbao:
    url: https://openbao.example.com:8200/v1/auth/approle/login
    roleId:
      existingSecret: permesi-openbao
      secretKey: role_id
    secretId:
      existingSecret: permesi-openbao
      secretKey: secret_id
```

## Operational options via extraEnv

The chart maps the common settings directly; the remaining CLI options are
available through `extraEnv`. Production-relevant examples:

```yaml
extraEnv:
  # SMTP delivery (password via a Secret reference)
  - name: PERMESI_EMAIL_DELIVERY
    value: "smtp"
  - name: PERMESI_SMTP_HOST
    value: "smtp.example.com"
  - name: PERMESI_SMTP_FROM
    value: "no-reply@example.com"
  - name: PERMESI_SMTP_USERNAME
    value: "permesi"
  - name: PERMESI_SMTP_PORT
    value: "465"
  - name: PERMESI_SMTP_TLS
    value: "implicit"
  - name: PERMESI_SMTP_PASSWORD
    valueFrom:
      secretKeyRef:
        name: smtp-credentials
        key: password

  # OIDC authority (issuer and audience must be set as a pair)
  - name: PERMESI_OIDC_ISSUER
    value: "https://permesi.example.com"
  - name: PERMESI_OAUTH_AUDIENCE
    value: "permesi"

  # Trusted reverse-proxy CIDRs. Never use 0.0.0.0/0: list only the ingress
  # peers that are allowed to overwrite client-IP headers.
  - name: PERMESI_AUTH_TRUSTED_PROXIES
    value: "10.0.0.0/8,192.168.0.0/16"
```

### Database pool budget

The per-process database pool is per pod. Budget connections across the maximum
replica count plus rollout surge (`autoscaling.maxReplicas` when enabled,
otherwise `replicaCount`), not just steady-state replicas. Tune
`PERMESI_DB_MIN_CONNECTIONS` / `PERMESI_DB_MAX_CONNECTIONS` via `extraEnv`.

## Validation rules

The chart enforces these invariants at render time:

- `service.enabled` must be `false` when `config.socketPath` is set.
- `openbao.secretId` and `openbao.wrappedToken` are mutually exclusive.
- In TCP `auto`/`approle` mode, `openbao.roleId` and one of `openbao.secretId` or
  `openbao.wrappedToken` must be configured. Native mode uses its Kubernetes role
  instead and rejects those AppRole credentials.
- `autoscaling.minReplicas` must not exceed `autoscaling.maxReplicas`.
- Any `externalSecret.remoteKey` requires a non-empty `externalSecret.store`.
- `openbao.roleId.existingSecret` and `openbao.secretId.existingSecret` must name
  the same Secret when OpenBao ESO is active.
- The application image (and, when enabled, the OpenBao Agent image) must be
  pinned by digest.
- `extraEnv` must not set `PERMESI_OPENBAO_*`, `GENESIS_OPENBAO_*`,
  `PERMESI_ADMISSION_ISS` or `PERMESI_ADMISSION_AUD`; use the chart values
  instead. `PERMESI_ADMISSION_REFRESH_SECONDS` and
  `PERMESI_ADMISSION_MAX_AGE_SECONDS` may be tuned there.
