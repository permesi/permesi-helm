# permesi chart

Production-oriented Helm chart for the permesi IAM service.

## What it exposes

This chart maps runtime configuration to the same environment variables used by
`permesi --help`, including:

- server mode (`PERMESI_PORT` or `PERMESI_SOCKET_PATH`)
- DB and TLS inputs (`PERMESI_DSN`, `PERMESI_TLS_PEM_BUNDLE`)
- admission verifier settings (`PERMESI_ADMISSION_*`)
- Vault auth and KV paths (`PERMESI_VAULT_*`)
- auth/session/outbox/OPAQUE/admin settings

## Secret handling

For sensitive fields you can use either:

- inline value (`*.value`) for local/dev
- Kubernetes Secret reference (`*.existingSecret` + `*.secretKey`) for production
- ExternalSecret (ESO) synthesis by enabling `externalSecret` and setting the
  item's `externalSecret.remoteKey`

This applies to `database.dsn`, `tls`, `vault` (role_id/secret_id), and
`admission.paserkCa`.

### ExternalSecret precedence

Each source resolves to one effective Secret name used consistently by both the
Deployment and any generated ExternalSecret:

1. An explicit `*.existingSecret` wins.
2. Otherwise, when `externalSecret.enabled` is true and that item's
   `externalSecret.remoteKey` is set, the chart uses the generated default
   target name (`<fullname>-db`, `<fullname>-tls`, `<fullname>-vault`,
   `<fullname>-admission-ca`).
3. Otherwise the value is used inline / the volume is not mounted, as before.

Vault ESO writes `role_id` and `secret_id` into a single Secret; the Deployment
reads both from that same Secret. Setting `vault.roleId.existingSecret` and
`vault.secretId.existingSecret` to different names while Vault ESO is active
fails rendering. Any `externalSecret.remoteKey` also requires a non-empty
`externalSecret.store`.

## Vault authentication

Permesi authenticates to Vault either through a Unix-socket Vault Agent
(`vault.url` does not start with `http://`/`https://`) or through direct
AppRole over TCP.

Direct AppRole POSTs to `PERMESI_VAULT_URL` exactly as supplied, so use the full
login endpoint rather than merely the origin:

```yaml
vault:
  url: https://vault.example.com:8200/v1/auth/approle/login
```

Agent socket mode is passed through unchanged.

A static one-use SecretID or a response-wrapped token is bootstrap-only: the
application logs in on every startup, so a shared one-use credential cannot
survive replicas or restarts. For multi-replica, restart-safe deployments prefer
the Vault Agent socket (auto-auth) or provision a SecretID with suitable
`secret_id_num_uses`/TTL rather than sharing a one-use credential.

## Vault Agent (managed sidecar, opt-in)

Set `vault.agent.enabled: true` to render a chart-managed Vault Agent native
sidecar (Kubernetes ≥ 1.29 with `SidecarContainers`). It authenticates via
Kubernetes auth and renders the TLS bundle and the PASERK CA, so the backend needs
no AppRole/TLS/PASERK Secrets. It reuses `vault.url` (Unix socket),
`tls.pemBundlePath`, and `admission.paserkCaPath`/`paserkCa.mountPath` as
destinations.

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
| `vault.agent.paserkCa.{enabled,path}` | `true`, `pki-int/cert/ca_chain` | Permesi-only PASERK CA template |

When enabled, the chart requires a Unix `vault.url`, an Agent address/role, and a
PKI role/SANs; requires `serviceAccount.automount=false`, nonroot UID/GID, and
compatible fsGroup; and rejects AppRole/wrapped/ESO Vault credentials, TLS
Secret/ESO, and PASERK Secret/ESO (for the artifacts the Agent now manages).
`config.socketPath` omits the inbound PKI template but keeps the Vault socket and
PASERK CA.

<!-- UNVERIFIED: exact keys/defaults and pinned Agent image tag confirmed by M-VA. -->

## Image digest precedence

Set `image.digest` (`sha256:<64 hex>`) to pin by digest: the chart renders
`repository@digest` and a tag change does not override it. Clear the digest to
return to `repository:tag`. <!-- UNVERIFIED: digest helper is M-DIG work. -->

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
    paserkUrl: https://genesis.permesi.svc.cluster.local:8080/paserk.json
  vault:
    url: https://vault.example.com:8200/v1/auth/approle/login
    roleId:
      existingSecret: permesi-vault
      secretKey: role_id
    secretId:
      existingSecret: permesi-vault
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
- `vault.secretId` and `vault.wrappedToken` are mutually exclusive.
- When `vault.url` is HTTP(S), `vault.roleId` and one of `vault.secretId` or
  `vault.wrappedToken` must be configured.
- `autoscaling.minReplicas` must not exceed `autoscaling.maxReplicas`.
- Any `externalSecret.remoteKey` requires a non-empty `externalSecret.store`.
- `vault.roleId.existingSecret` and `vault.secretId.existingSecret` must name
  the same Secret when Vault ESO is active.
