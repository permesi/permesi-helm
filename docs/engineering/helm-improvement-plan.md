# Helm improvement plan

## Decision

Keep the existing four-chart structure and values interfaces. Fix demonstrated wiring defects, add deployment-specific validation, and provide a tested production configuration using the existing Secret, ConfigMap, `extraEnv`, annotation, and volume extension points.

Do not introduce a chart library, bundled PostgreSQL/Vault, automatic database migration hooks, or a new authentication mechanism. None is necessary to resolve the identified gaps.

**Priority assessment:** No unconditional P0 defect was established for a correctly configured deployment. Several P1 defects or production-readiness gaps are confirmed below. Defaults alone are not a runnable stack: they reference externally provisioned database, TLS, and Vault resources.

Paths below are relative to the parent workspace: `permesi/` is application source; `permesi-helm/` is chart source.

## 1. Application runtime requirements

### 1.1 Runtime topology and persistence

| Component | Authoritative behavior | Chart compatibility |
|---|---|---|
| Permesi | IAM service with opt-in OAuth/OIDC authority. TLS listener on 8080 or a Unix socket. Fetches Genesis public admission keys; authenticates to Vault; acquires dynamic PostgreSQL credentials; loads OPAQUE/MFA secrets; optionally initializes OIDC signing. | Core port, DSN, TLS, admission, Vault, and older auth settings are mapped. Newer options remain available through `extraEnv`/`extraEnvFrom`. |
| Genesis | Admission-token issuer. TLS listener on 8080 or a Unix socket. Uses Vault’s `genesis-signing` Ed25519 key; stores token/client data in PostgreSQL; exposes `/token` and `/paserk.json`. | Core configuration is mapped correctly, including the unusually named `GENESIS_TRANSIT_MOUNT`. |
| Web | Client-side Leptos/WASM application served by nginx on HTTP 8080. Browser—not nginx—calls Permesi and Genesis. Reads `/config.js` into `window.PERMESI_CONFIG`. | Correct ConfigMap path, port, service target, and `/healthz` probes. Runtime configuration validation and upgrade behavior need fixes. |
| PostgreSQL | External persistence. Both services obtain credentials from Vault and replace the username/password in their DSNs. One bounded pool per process; no application-run migrations. | No bundled database or PVC is required for application pods. External database provisioning and schema upgrades need an explicit runbook. |
| Vault | Application supports direct AppRole authentication or a Unix-socket Vault Agent proxy. No application-native Kubernetes auth or arbitrary `VAULT_TOKEN` login mode was found. | Existing Secret/env/annotation/volume extension points are usable, but do not themselves provision a functioning agent. |

Evidence: application `services/permesi/src/cli/actions/server.rs:60-142`, `services/genesis/src/api/mod.rs:65-87`, `crates/service_utils/src/vault/database.rs:24-55`, `crates/service_utils/src/database.rs:140-174`, `db/sql/README.md:5-27`; charts `charts/permesi/templates/deployment.yaml:53-166`, `charts/genesis/templates/deployment.yaml:49-112`, `charts/web/templates/deployment.yaml:43-64`.

### 1.2 Backend CLI/environment inventory

Legend:

- **Required** means required by clap or startup validation.
- **Conditional** means required only in the stated mode.
- **E** means supported through existing `extraEnv`/`extraEnvFrom`, but not a dedicated values field.
- Defaults below are application defaults, not necessarily chart defaults.
- `--help`/`-h` and `--version`/`-V` are clap-generated informational options.

#### Shared backend settings

For each row, both environment names are shown explicitly.

| CLI flag | Environment variables | Required | Application default | Chart mapping |
|---|---|---|---|---|
| `--socket-path` | `PERMESI_SOCKET_PATH`, `GENESIS_SOCKET_PATH` | No | Unset | `config.socketPath`; correctly suppresses port/TLS env and Service |
| `-p`, `--port` | `PERMESI_PORT`, `GENESIS_PORT` | No | 8080 | `config.port` |
| `-d`, `--dsn` | `PERMESI_DSN`, `GENESIS_DSN` | Yes | None | `database.dsn.value` or Secret |
| `--tls-pem-bundle` | `PERMESI_TLS_PEM_BUNDLE`, `GENESIS_TLS_PEM_BUNDLE` | TCP mode | None | `tls.pemBundlePath`, `tls.existingSecret` |
| `--vault-url` | `PERMESI_VAULT_URL`, `GENESIS_VAULT_URL` | Yes | None | `vault.url`; important service-specific URL semantics, F-01 |
| `--vault-role-id` | `PERMESI_VAULT_ROLE_ID`, `GENESIS_VAULT_ROLE_ID` | TCP mode | None | `vault.roleId` |
| `--vault-secret-id` | `PERMESI_VAULT_SECRET_ID`, `GENESIS_VAULT_SECRET_ID` | TCP mode unless wrapped token | None | `vault.secretId` |
| `--vault-wrapped-token` | `PERMESI_VAULT_WRAPPED_TOKEN`, `GENESIS_VAULT_WRAPPED_TOKEN` | Alternative to SecretID | None | `vault.wrappedToken`; lifecycle caveat, F-02 |
| `--vault-transit-mount` | `PERMESI_VAULT_TRANSIT_MOUNT`, **`GENESIS_TRANSIT_MOUNT`** | No | `transit/permesi`, `transit/genesis` | `vault.transitMount`; **OK** |
| `-v`, `--verbose` | `PERMESI_LOG_LEVEL`, `GENESIS_LOG_LEVEL` | No | ERROR | `config.logLevel`; chart intentionally defaults to `info` |
| `--db-max-connections` | `PERMESI_DB_MAX_CONNECTIONS`, `GENESIS_DB_MAX_CONNECTIONS` | No | 10 | E |
| `--db-min-connections` | `PERMESI_DB_MIN_CONNECTIONS`, `GENESIS_DB_MIN_CONNECTIONS` | No | 2 | E |
| `--db-acquire-timeout-ms` | `PERMESI_DB_ACQUIRE_TIMEOUT_MS`, `GENESIS_DB_ACQUIRE_TIMEOUT_MS` | No | 3000 | E |
| `--db-idle-timeout-seconds` | `PERMESI_DB_IDLE_TIMEOUT_SECONDS`, `GENESIS_DB_IDLE_TIMEOUT_SECONDS` | No | 600 | E |
| `--db-max-lifetime-seconds` | `PERMESI_DB_MAX_LIFETIME_SECONDS`, `GENESIS_DB_MAX_LIFETIME_SECONDS` | No | 1800 | E |

Sources: `permesi/services/permesi/src/cli/commands/mod.rs:250-289`, `commands/{tls,vault,logging}.rs`, `commands/database.rs:47-90`; Genesis equivalents, particularly `services/genesis/src/cli/commands/vault.rs:6-36`. Chart mapping: both backend `templates/deployment.yaml`; extension points at Permesi lines 160-165 and Genesis lines 106-111.

Pool constraints: maximum 1–200; minimum ≤ maximum; acquire timeout 100–30000 ms; idle timeout ≥10 seconds and below lifetime; lifetime 60–86400 seconds. Budget connections across maximum replicas **and rollout surge**, not just steady-state replicas (`crates/service_utils/src/database.rs:79-109`).

#### Permesi-specific, dedicated mappings

All are optional except `PERMESI_ADMISSION_PASERK_URL`.

| CLI flag | Environment variable | Default | Chart mapping |
|---|---|---|---|
| `--vault-kv-mount` | `PERMESI_VAULT_KV_MOUNT` | `secret/permesi` | `vault.kvMount` |
| `--vault-kv-path` | `PERMESI_VAULT_KV_PATH` | `config` | `vault.kvPath` |
| `--admission-paserk-url` | `PERMESI_ADMISSION_PASERK_URL` | None; required | `admission.paserkUrl` |
| `--admission-issuer` | `PERMESI_ADMISSION_ISS` | `https://genesis.permesi.dev` | `admission.issuer`; omitted when empty |
| `--admission-audience` | `PERMESI_ADMISSION_AUD` | `permesi` | `admission.audience`; omitted when empty |
| `--admission-paserk-ca-path` | `PERMESI_ADMISSION_PASERK_CA_PATH` | Unset | `admission.paserkCaPath` or generated Secret mount path |
| `--frontend-base-url` | `PERMESI_FRONTEND_BASE_URL` | `https://permesi.dev` | `auth.frontendBaseUrl` |
| `--cors-allowed-origins` | `PERMESI_CORS_ALLOWED_ORIGINS` | None additional | `auth.corsAllowedOrigins` |
| `--email-token-ttl-seconds` | `PERMESI_EMAIL_TOKEN_TTL_SECONDS` | 1800 | `auth.emailTokenTtlSeconds` |
| `--email-resend-cooldown-seconds` | `PERMESI_EMAIL_RESEND_COOLDOWN_SECONDS` | 60 | `auth.emailResendCooldownSeconds` |
| `--session-ttl-seconds` | `PERMESI_SESSION_TTL_SECONDS` | 604800 | `auth.sessionTtlSeconds` |
| `--email-outbox-poll-seconds` | `PERMESI_EMAIL_OUTBOX_POLL_SECONDS` | 5 | `auth.emailOutboxPollSeconds` |
| `--email-outbox-batch-size` | `PERMESI_EMAIL_OUTBOX_BATCH_SIZE` | 10 | `auth.emailOutboxBatchSize` |
| `--email-outbox-max-attempts` | `PERMESI_EMAIL_OUTBOX_MAX_ATTEMPTS` | 5 | `auth.emailOutboxMaxAttempts` |
| `--email-outbox-backoff-base-seconds` | `PERMESI_EMAIL_OUTBOX_BACKOFF_BASE_SECONDS` | 5 | `auth.emailOutboxBackoffBaseSeconds` |
| `--email-outbox-backoff-max-seconds` | `PERMESI_EMAIL_OUTBOX_BACKOFF_MAX_SECONDS` | 300 | `auth.emailOutboxBackoffMaxSeconds` |
| `--opaque-server-id` | `PERMESI_OPAQUE_SERVER_ID` | `api.permesi.dev` | `auth.opaqueServerId` |
| `--opaque-login-ttl-seconds` | `PERMESI_OPAQUE_LOGIN_TTL_SECONDS` | 300 | `auth.opaqueLoginTtlSeconds` |
| `--platform-admin-ttl-seconds` | **`PLATFORM_ADMIN_TTL_SECONDS`** | 43200 | `auth.platformAdminTtlSeconds`; **OK** |
| `--platform-recent-auth-seconds` | **`PLATFORM_RECENT_AUTH_SECONDS`** | 3600 | `auth.platformRecentAuthSeconds`; **OK** |

Sources: `permesi/services/permesi/src/cli/commands/admission.rs:18-73`, `vault.rs:83-102`, `auth.rs:187-352`; chart `permesi-helm/charts/permesi/templates/deployment.yaml:76-159`.

#### Permesi settings available through E

These settings are **not inaccessible**: the chart already supports them through generic environment extension points. A production example should expose the important combinations without duplicating every CLI setting in values.

Unless noted, required = no.

| CLI flag | Environment variable | Default / conditional requirement |
|---|---|---|
| `--signup-mode` | `PERMESI_SIGNUP_MODE` | `public`; public/restricted/closed |
| `--signup-allowed-domain` | `PERMESI_SIGNUP_ALLOWED_DOMAINS` | Unset; required for restricted mode |
| `--signup-development-domain` | `PERMESI_SIGNUP_DEVELOPMENT_DOMAINS` | Unset; reserved development domains, outbox mode only |
| `--email-delivery` | `PERMESI_EMAIL_DELIVERY` | **`outbox`**, not SMTP |
| `--smtp-host` | `PERMESI_SMTP_HOST` | Required for SMTP |
| `--smtp-from` | `PERMESI_SMTP_FROM` | Required for SMTP |
| `--smtp-username` | `PERMESI_SMTP_USERNAME` | Optional; requires password |
| `--smtp-password` | `PERMESI_SMTP_PASSWORD` | Optional; requires username; use Secret reference |
| `--smtp-port` | `PERMESI_SMTP_PORT` | 465 |
| `--smtp-tls` | `PERMESI_SMTP_TLS` | `implicit`; alternative `starttls` |
| `--smtp-timeout-seconds` | `PERMESI_SMTP_TIMEOUT_SECONDS` | 10 |
| `--email-lease-seconds` | `PERMESI_EMAIL_LEASE_SECONDS` | 60 |
| `--auth-registration-timeout-ms` | `PERMESI_AUTH_REGISTRATION_TIMEOUT_MS` | 1000 |
| `--auth-max-pending-states` | `PERMESI_AUTH_MAX_PENDING_STATES` | 10000 |
| `--opaque-exchange-timeout-ms` | `PERMESI_OPAQUE_EXCHANGE_TIMEOUT_MS` | 1000 |
| `--auth-rate-limit-window-seconds` | `PERMESI_AUTH_RATE_LIMIT_WINDOW_SECONDS` | 600 |
| `--auth-rate-limit-ip-attempts` | `PERMESI_AUTH_RATE_LIMIT_IP_ATTEMPTS` | 100 |
| `--auth-rate-limit-account-attempts` | `PERMESI_AUTH_RATE_LIMIT_ACCOUNT_ATTEMPTS` | 10 |
| `--auth-pending-subject-limit` | `PERMESI_AUTH_PENDING_SUBJECT_LIMIT` | 16 |
| `--auth-pending-login-limit` | `PERMESI_AUTH_PENDING_LOGIN_LIMIT` | 10000 |
| `--auth-pending-reauth-limit` | `PERMESI_AUTH_PENDING_REAUTH_LIMIT` | 1000 |
| `--auth-pending-registration-limit` | `PERMESI_AUTH_PENDING_REGISTRATION_LIMIT` | 1000 |
| `--auth-pending-mfa-limit` | `PERMESI_AUTH_PENDING_MFA_LIMIT` | 1000 |
| `--mfa-challenge-max-attempts` | `PERMESI_MFA_CHALLENGE_MAX_ATTEMPTS` | 5 |
| `--auth-trusted-proxy` | `PERMESI_AUTH_TRUSTED_PROXIES` | No trusted proxy CIDRs |
| `--auth-trust-unix-proxy` | `PERMESI_AUTH_TRUST_UNIX_PROXY` | false |
| `--passkeys-rp-id` | `PERMESI_PASSKEYS_RP_ID` | Derived from frontend configuration |
| `--passkeys-rp-name` | `PERMESI_PASSKEYS_RP_NAME` | `Permesi` |
| `--passkeys-allowed-origins` | `PERMESI_PASSKEYS_ALLOWED_ORIGINS` | Derived from frontend/CORS configuration |
| `--passkeys-challenge-ttl-seconds` | `PERMESI_PASSKEYS_CHALLENGE_TTL_SECONDS` | 300 |
| `--passkeys-preview-mode` | `PERMESI_PASSKEYS_PREVIEW_MODE` | false |
| `--oidc-issuer` | `PERMESI_OIDC_ISSUER` | Unset; paired with audience; canonical HTTPS origin |
| `--oauth-audience` | `PERMESI_OAUTH_AUDIENCE` | Unset; paired with issuer |
| `--oidc-signing-key` | `PERMESI_OIDC_SIGNING_KEY` | `oidc-signing` |
| `--oauth-code-ttl-seconds` | `PERMESI_OAUTH_CODE_TTL_SECONDS` | 120 |
| `--oauth-access-token-ttl-seconds` | `PERMESI_OAUTH_ACCESS_TOKEN_TTL_SECONDS` | 300 |
| `--oauth-refresh-absolute-ttl-seconds` | `PERMESI_OAUTH_REFRESH_ABSOLUTE_TTL_SECONDS` | 2592000 |
| `--oauth-refresh-idle-ttl-seconds` | `PERMESI_OAUTH_REFRESH_IDLE_TTL_SECONDS` | 604800 |
| `--oauth-token-rate-window-seconds` | `PERMESI_OAUTH_TOKEN_RATE_WINDOW_SECONDS` | 60 |
| `--oauth-token-rate-ip-attempts` | `PERMESI_OAUTH_TOKEN_RATE_IP_ATTEMPTS` | 120 |
| `--oauth-token-rate-client-ip-attempts` | `PERMESI_OAUTH_TOKEN_RATE_CLIENT_IP_ATTEMPTS` | 30 |
| `--oidc-id-token-ttl-seconds` | `PERMESI_OIDC_ID_TOKEN_TTL_SECONDS` | 300 |
| `--oauth-token-timeout-ms` | `PERMESI_OAUTH_TOKEN_TIMEOUT_MS` | 5000 |
| `--oauth-token-max-body-bytes` | `PERMESI_OAUTH_TOKEN_MAX_BODY_BYTES` | 8192 |
| `--oauth-request-ttl-seconds` | `PERMESI_OAUTH_REQUEST_TTL_SECONDS` | 600 |
| `--oauth-lock-timeout-ms` | `PERMESI_OAUTH_LOCK_TIMEOUT_MS` | 1000 |
| `--tenant-lock-timeout-ms` | `PERMESI_TENANT_LOCK_TIMEOUT_MS` | 1000 |
| `--tenant-mutation-timeout-ms` | `PERMESI_TENANT_MUTATION_TIMEOUT_MS` | 5000 |
| `--tenant-slug-attempts` | `PERMESI_TENANT_SLUG_ATTEMPTS` | 16 |
| `--oauth-client-secret-grace-seconds` | `PERMESI_OAUTH_CLIENT_SECRET_GRACE_SECONDS` | 900 |
| `--oauth-client-secret-memory-kib` | `PERMESI_OAUTH_CLIENT_SECRET_MEMORY_KIB` | 19456 |
| `--oauth-client-secret-iterations` | `PERMESI_OAUTH_CLIENT_SECRET_ITERATIONS` | 2 |
| `--oauth-client-secret-parallelism` | `PERMESI_OAUTH_CLIENT_SECRET_PARALLELISM` | 1 |
| `--oauth-client-secret-hash-workers` | `PERMESI_OAUTH_CLIENT_SECRET_HASH_WORKERS` | 2 |
| `--oidc-jwks-cache-ttl-seconds` | `PERMESI_OIDC_JWKS_CACHE_TTL_SECONDS` | 30 |

Sources: `permesi/services/permesi/src/cli/commands/mod.rs:14-200,294-365`, `auth.rs:290-332`, `cli/dispatch/mod.rs:37-65`. SMTP cross-field validation: `api/email/config.rs:42-116`.

#### Direct environment reads and image environment

No CLI flag for these. All are optional and use E unless otherwise noted.

| Service | Variable | Default / semantics |
|---|---|---|
| Permesi | `PERMESI_MFA_REQUIRED` | false; recognizes `1/true/TRUE/yes/YES` and `0/false/FALSE/no/NO`; invalid values fall back to false |
| Genesis | `GENESIS_ADMISSION_ISS` | `https://genesis.permesi.dev`; must match verifier |
| Genesis | `GENESIS_ADMISSION_AUD` | `permesi`; must match verifier |
| Genesis | `GENESIS_IP_HEADER` | `CF-Connecting-IP`; metadata, not a trusted-proxy authentication boundary |
| Genesis | `GENESIS_COUNTRY_HEADER` | `CF-IPCountry`; metadata |
| Both | `RUST_LOG` | Optional logging filter combined with configured default level |
| Both | `OTEL_EXPORTER_OTLP_ENDPOINT` | No exporter unless configured and telemetry feature enabled |
| Both | `OTEL_EXPORTER_OTLP_PROTOCOL` | gRPC only; other setting logged/ignored |
| Both | `OTEL_EXPORTER_OTLP_HEADERS` | Empty; may carry credentials, use Secret |
| Both | `OTEL_SERVICE_INSTANCE_ID` | Generated ULID |
| Both images | `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt`; image-provided trust bundle |

Sources: `permesi/services/permesi/src/api/handlers/auth/mfa/mod.rs:55,186-202`; `services/genesis/src/api/admission.rs:80-83`, `handlers/token.rs:142-145`; both `cli/telemetry.rs:59,125-172,211-246`; both backend Dockerfiles.

Dependency-internal environment behavior such as SQLx’s `PG*` variables was not established from application source and should not be documented as an application-supported contract without separate verification.

### 1.3 Web runtime configuration

These are browser configuration keys, **not runtime container environment variables**.

| Key | Compile-time environment / fallback | Required for useful deployment | Chart mapping |
|---|---|---|---|
| `api_base_url` | `PERMESI_API_BASE_URL`, then `PERMESI_API_HOST`, then empty | Yes for this static nginx deployment | `runtimeConfig.apiBaseUrl` |
| `token_base_url` | `PERMESI_TOKEN_BASE_URL`, then empty | Yes | `runtimeConfig.tokenBaseUrl` |
| `client_id` | `PERMESI_CLIENT_ID`, then empty | Yes; must identify a provisioned Genesis client | `runtimeConfig.clientId` |
| `opaque_server_id` | `PERMESI_OPAQUE_SERVER_ID`, then `api.permesi.dev` | Must match backend | `runtimeConfig.opaqueServerId` |

Runtime nonempty strings override compile-time values; empty strings are ignored. Published-build workflow defaults target `api.permesi.com`/`genesis.permesi.com`, with OPAQUE ID `api.permesi.com`, and an all-zero client ID if the CI variable is absent.

Evidence: `permesi/apps/web/src/lib/config.rs:16-36,64-103`, `features/auth/token.rs:18-33`, `.github/workflows/deploy.yml:292-309`; chart `charts/web/values.yaml:36-42`, `templates/configmap-runtime.yaml:10-12`.

Setting `PERMESI_API_BASE_URL` in chart `extraEnv` does not rebuild WASM and therefore does not configure this client.

### 1.4 Vault, crypto, and split trust

- **Permesi direct AppRole URL:** POSTs to `PERMESI_VAULT_URL` exactly as supplied. For the standard mount, use `https://vault:8200/v1/auth/approle/login`, not merely the origin. Genesis normalizes a base URL to the standard login endpoint. See F-01.
- **Agent mode:** the Unix socket must already be accessible when the transport is constructed. The application supplies no service token; the agent must provide automatic authentication. An injector may use Kubernetes auth, but that is agent infrastructure, not a service CLI feature.
- **Dynamic PostgreSQL credentials:** fixed Vault paths `/v1/database/creds/permesi` and `/v1/database/creds/genesis`. DSN credentials are always replaced.
- **Permesi secrets:** KV v2 `secret/permesi/data/config` contains OPAQUE seed and MFA recovery pepper. Transit `totp` supports data-key generation/decryption. Optional OIDC uses the separate RSA-2048 `oidc-signing` key.
- **Genesis:** signs admission tokens using Vault transit `genesis-signing` Ed25519 key. Private signing material is not distributed to Permesi.
- **Key distribution:** Genesis publishes public PASERK keys at `/paserk.json`; Permesi fetches them over HTTPS and verifies admission tokens locally. Genesis publishes latest and previous versions; caches are approximately 300 seconds. Permesi can refresh on unknown key IDs, throttled to 30 seconds.
- **Browser flow:** browser calls Genesis `/token?client_id=…`, then presents admission material to Permesi. Genesis does not need a callback to Permesi to verify admission tokens.
- **Do not confuse keysets:** Permesi’s `/jwks.json` and `/.well-known/openid-configuration` belong to its OIDC authority, not Genesis admission verification.

Evidence: `permesi/services/permesi/src/cli/actions/server.rs:73-131`, `services/permesi/src/vault/mod.rs:24-36`, `crates/vault_client/src/lib.rs:121-165`, `services/genesis/src/vault/mod.rs:18-26`, `crates/vault_client/src/transport.rs:125-148,400-419`, `services/genesis/src/api/admission.rs:30-31,200-295`, `services/permesi/src/api/handlers/mod.rs:133-171,296-311`, `oauth/oidc/signing.rs:33-91`, `api/openapi.rs:489-500`, `apps/web/src/features/auth/token.rs:32-33`.

### 1.5 TLS, probes, startup, and shutdown

| Concern | Runtime requirement |
|---|---|
| Inbound backend TLS | Required in TCP mode; one PEM bundle with key and certificate chain. No client-certificate authentication. Plain HTTP backend routing is wrong. |
| Certificate reload | Watches bundle modification time every 10 seconds. Existing directory Secret mounts allow projection updates; do not replace them with subPath mounts. |
| PASERK trust | System roots plus `PERMESI_ADMISSION_PASERK_CA_PATH`. The server’s TLS bundle is not automatically the outbound Genesis trust store. |
| Vault trust | System/root-bundle configuration; no dedicated Vault CA CLI flag. |
| PostgreSQL TLS | DSN controls SQLx connection options. Production should explicitly configure certificate validation and the required CA file; chart defaults currently say `sslmode=disable`. |
| Backend `/live` | Dependency-free 200; correct liveness target. |
| Permesi `/ready`, `/health` | Check PostgreSQL and admission-keyset health; not a general Vault-health check. |
| Genesis `/ready`, `/health` | Check PostgreSQL; do not verify current transit-signing availability. |
| DB authentication failure | Probe can initiate fail-closed shutdown so restart obtains fresh Vault credentials. |
| Web `/healthz` | nginx-only 200; does not prove valid runtime config or functioning API/Genesis. |
| Startup failure | Required Vault/DB/KV/Genesis-signing initialization failures prevent serving. Permesi PASERK fetch failure normally leaves an empty stale cache and unready verifier; the initial HTTP fetch has no explicit timeout. |
| Shutdown | SIGTERM/SIGINT → bounded 30-second request drain. Permesi then permits 10 seconds for email-worker shutdown, 5 seconds for pool close, and telemetry flush. Fail-closed shutdown returns an error. |

Evidence: `permesi/crates/service_utils/src/tls.rs:239-312`, `services/permesi/src/api/handlers/health.rs:49-110,180-215`, Genesis `health.rs:40-96`, `crates/service_utils/src/shutdown.rs:21-77`, `services/permesi/src/api/mod.rs:208-238,365-395`, `crates/service_utils/src/database.rs:48,190-199`, `apps/web/nginx.conf:46-50`.

**Startup signal handling:** signal listeners are installed when serving begins. PID-1 behavior during earlier initialization was not exercised; do not claim startup SIGTERM is gracefully handled.

### 1.6 Images and versions

- Workspace version: `0.4.3` (`permesi/Cargo.toml:15-16`).
- Charts, appVersions, dependency versions, and default image tags currently agree on `0.4.3`.
- Repositories: `ghcr.io/permesi/permesi`, `ghcr.io/permesi/genesis`, `ghcr.io/permesi/web`.
- Backend images are static musl binaries in `scratch`, with image user `65532:65532`, bundled CA roots, port 8080, and direct executable entrypoints. Charts deliberately override UID/GID to `10001`; this is not inherently incorrect.
- Web Dockerfile inherits `nginxinc/nginx-unprivileged:stable-alpine`; chart sets UID/GID 101 and supplies writable `/tmp` and `/var/cache/nginx`.
- Upstream nginx image user, PID paths, and stop signal were not inspected from the resolved image. Treat exact inherited behavior as **[INFERENCE]** until image smoke tests.
- No shell exists in the backend image: do not propose shell-based exec probes or `preStop: exec: sleep`.

Evidence: backend Dockerfiles `:16-34`; `apps/web/Dockerfile:1-6`; three chart `values.yaml:7-34`; `charts/permesi-stack/Chart.yaml:6-20`; application release workflow `.github/workflows/deploy.yml:724-752`.

## 2. Compatibility matrix

“Gap” means a confirmed defect or a documented production-readiness gap, not that the chart cannot be configured successfully. Stack entries include inherited component behavior.

| Area | Permesi | Genesis | Web | Stack |
|---|---|---|---|---|
| 1. Runtime config parity | OK core; production examples gap F-09 | OK core; E for extra settings | Gap F-07 | Gap F-04/F-09 |
| 2. Env mappings | OK, including unprefixed admin vars | OK, including `GENESIS_TRANSIT_MOUNT` | OK ConfigMap mechanism; env distinction undocumented | Inherits |
| 3. Secrets | Gap ESO wiring F-03 | Gap ESO wiring F-03 | OK public runtime data | Inherits |
| 4. Vault | Gap F-01/F-02 | Gap lifecycle F-02 | OK, not used | Inherits |
| 5. TLS/trust | Gap production profile F-05 | Gap production profile F-05 | OK HTTP backend; external TLS configurable | Gap F-04/F-05 |
| 6. NetworkPolicies | OK opt-in raw rules; examples gap F-12 | Same | Same; browser calls do not require nginx egress | Gap examples |
| 7. Least privilege | Good baseline; gap F-10 | Same | Good baseline; gap F-10 | Inherits |
| 8. Probes | OK endpoints/schemes | OK endpoints/schemes | OK nginx health | Inherits |
| 9. Resources | OK configurable requests/limits; sizing unverified | Same | Same | Inherits |
| 10. HPA | OK v2, requests present, replicas omitted when enabled | Same | Same | Inherits; DB budget undocumented |
| 11. PDB/rollouts | OK two replicas/minAvailable 1; native RollingUpdate | Same | Same | No distinct controller |
| 12. Graceful termination | Gap F-08 | Gap F-08 | 30 seconds configurable; image drain unverified | Inherits |
| 13. Discovery/ingress | Gap F-04/F-05/F-09 | TLS ingress examples gap | Runtime external URLs gap F-07 | Gap F-04 |
| 14. Dependencies/schema | Existing schema useful; targeted gaps F-03/F-13 | Same | Gap required runtime fields F-07 | Dependencies OK; no parent schema |
| 15. Image/release sync | OK 0.4.3 | OK 0.4.3 | OK 0.4.3 | OK 0.4.3; release runbook gap F-13 |
| 16. Upgrade safety | Gap credential/schema/drain runbooks | Gap credential/schema/drain runbooks | Gap runtime rollover F-06 | Inherits |
| 17. Helm CI/tests | Gap F-11 | Gap F-11 | Gap F-11 | Gap F-11 |
| 18. Docs/examples | Gap F-01/F-05/F-09 | Gap F-02/F-05 | Gap F-06/F-07 | Gap F-04/F-13 |

PDB absence is **not** a finding: PDBs already exist. Explicit rolling-update settings are not required for correctness: Kubernetes supplies RollingUpdate defaults. Topology spreading and affinity are exposed; missing mandatory spreading is a workload-policy decision, not a demonstrated defect.

## 3. Findings

### F-01 — P1 — Documented Permesi Vault base URL fails AppRole login

**Evidence:** Application `permesi/services/permesi/src/cli/actions/server.rs:93-112`, `src/vault/mod.rs:34-36`, `crates/vault_client/src/lib.rs:121-165` POST directly to the supplied URL. Chart examples use `https://vault.example.com:8200`: `permesi-helm/charts/permesi/README.md:44-52`, root `README.md:68-76`; deployment forwards it unchanged at `templates/deployment.yaml:91-92`.

**Impact:** Following the documented direct-AppRole example sends login to Vault’s root, not `/v1/auth/approle/login`, preventing startup. Genesis has a normalizer; Permesi does not.

**Minimal solution:** Correct Permesi examples and NOTES to use the full AppRole login endpoint. Document the difference explicitly. Do not silently rewrite arbitrary URLs or modify application source.

**Risks/dependencies:** Preserve custom auth-mount paths and agent socket URLs.

**Acceptance/validation:** Example renders the complete endpoint; real Vault login and database credential acquisition succeed. Genesis base-URL behavior remains unchanged.

### F-02 — P1 — Static one-use credentials are incompatible with replicas and restart recovery

**Evidence:** Both charts default to two replicas and inject the same SecretID/wrapped token into each pod: backend `values.yaml:5` and Permesi deployment `:103-121`/Genesis `:84-102`. Application unwraps/logs in on every startup (`permesi/services/permesi/src/cli/actions/server.rs:99-112`). Supplied Vault Terraform sets `secret_id_num_uses = 1` and a one-hour SecretID TTL (`vault/contrib/terraform/approle.tf:6-28`). Renewal failure deliberately triggers application restart.

**Impact:** With those Vault roles, at most one pod can consume a shared SecretID; replicas or subsequent restarts fail. A response-wrapping token cannot be reused even if the underlying SecretID permits multiple logins.

**Minimal solution:** Document and test a restart-safe production authentication profile. Prefer externally managed Vault Agent auto-auth with a correctly shared, ready socket, using existing annotation/volume controls. Keep direct AppRole supported, but require operators to supply credentials with suitable use/TTL provisioning. Clearly label static wrapped tokens as bootstrap-only, not HA credentials.

**Risks/dependencies:** No weakening of supplied Vault policies. Agent startup ordering and socket UID/GID access must be demonstrated. Agent Kubernetes auth may need a projected service-account token.

**Acceptance/validation:** Two replicas start, each restarts successfully, scale-out works, and lease renewal failure recovers. Negative test confirms shared one-use credentials fail as documented.

### F-03 — P1 — ExternalSecret producers and consumers resolve different names

**Evidence:** Both `templates/external-secret.yaml:20,41,62` generate default targets `<fullname>-db`, `-tls`, and `-vault`. Deployments consume secrets only when explicit `existingSecret` fields are set; otherwise DSN stays inline and TLS is not mounted. Permesi deployment `:66-73,93-118,167-178`; Genesis `:62-69,74-99,113-118`. Vault ESO writes both credentials to the role-ID target, while consumers allow different role-ID and SecretID target names. Permesi admission CA ESO additionally requires `existingSecret` at `external-secret.yaml:73`.

Application needs the actual mounted TLS bundle and supplied Vault credentials: `permesi/services/permesi/src/cli/actions/server.rs:93-118`, `crates/service_utils/src/tls.rs:239-265`.

**Impact:** Enabling remote keys alone can create unused Secrets; mismatched Vault target names can leave a pod referencing a Secret ESO never creates.

**Minimal solution:** Within each chart, introduce small effective-secret-name helpers used consistently by validation, Deployment, and ExternalSecret. Preserve explicit names; derive the existing default target names when ESO is active. Reject conflicting explicit names for a single generated Vault credential Secret. Validate nonempty store when ESO resources are requested.

**Risks/dependencies:** ESO CRD version must support `external-secrets.io/v1`. Do not change naming for already explicit configurations.

**Acceptance/validation:** Render assertions cover inline, preexisting Secret, ESO-only remote keys, explicit targets, incompatible Vault names, and admission CA. Real ESO reconciliation proves generated resources are consumed.

### F-04 — P1 — Default admission DNS is not the umbrella’s generated Genesis Service

**Evidence:** Permesi default URL is `https://genesis.permesi.svc.cluster.local:8080/paserk.json` (`permesi-helm/charts/permesi/values.yaml:59`). Genesis fullname includes release name unless overridden (`charts/genesis/templates/_helpers.tpl:6-16`); Service uses that fullname (`templates/service.yaml:7`). Umbrella supplies no override (`charts/permesi-stack/values.yaml:15-34`). Application readiness requires a healthy admission keyset (`permesi/services/permesi/src/api/handlers/health.rs:201-203`).

**Example:** Release `permesi` in namespace `permesi` creates `permesi-genesis`, not `genesis`.

**Minimal solution:** Publish an explicit production stack profile whose `admission.paserkUrl` matches its documented release/namespace/service name, port, and certificate SAN. Document how name overrides affect the endpoint. Do not rename existing Services or introduce implicit sibling-value mutation.

**Risks/dependencies:** Changing fullname defaults would recreate resources and is rejected. Private CA/SAN requirements are coupled to F-05.

**Acceptance/validation:** Render at least two release/namespace combinations and assert the configured endpoint resolves to the actual Genesis Service. In-cluster HTTPS fetch succeeds; Permesi becomes ready.

### F-05 — P1 — Production TLS, database, and schema prerequisites are incomplete

**Evidence:** Backend default DSNs explicitly disable TLS (`permesi-helm/charts/{permesi,genesis}/values.yaml:43`). Ingress templates forward to TLS-serving Services without controller-specific backend protocol guidance (`templates/ingress.yaml:10-30`). Chart README examples do not explain combined PEM bundles, separate outbound trust, or schema ordering. Application TLS uses a combined bundle and no-client-auth listener (`permesi/crates/service_utils/src/tls.rs:239-265,315-347`); dynamic DB credentials are injected (`services/permesi/src/cli/actions/server.rs:118-131`); schema reapplication is required before rollout (`db/sql/README.md:16-27,43-50,80-93`).

**Minimal solution:** Add one production runbook/profile:
- External PostgreSQL persistence/backups and owner-driven schema application before rollout.
- DSN TLS verification and CA-volume example.
- Combined key/certificate bundle Secret format.
- Separate Genesis PASERK CA and Vault trust setup.
- Controller-specific HTTPS backend example; frontend TLS and backend TLS are separate.
- Explicit statement that Helm rollback does not roll back database schema.

Keep development DSNs labeled as such; do not silently alter existing DSN strings.

**Risks/dependencies:** Private-root handling depends on client library/image trust behavior and requires real TLS tests. Do not use automatic migration hooks or runtime superuser credentials.

**Acceptance/validation:** Fresh and upgrade deployments succeed against certificate-validating PostgreSQL/Vault/Genesis; wrong CA/SAN fails closed; certificate rotation is observed; pre-upgrade schema checks pass.

### F-06 — P1 — Web runtime ConfigMap changes do not roll pods

**Evidence:** `permesi-helm/charts/web/templates/deployment.yaml:19-27` has no generated configuration checksum; config is mounted with subPath at `:55-58`. ConfigMap contents change independently at `templates/configmap-runtime.yaml:10-12`. The browser loads that file through `permesi/apps/web/src/lib/config.rs:64-81`.

**Impact:** A runtimeConfig-only Helm upgrade leaves running pods serving the old file. A subPath mount is not live-updated.

**Minimal solution:** Add a checksum pod annotation for chart-managed runtime configuration, merging existing user annotations. For `existingConfigMap`, document explicit rollout using the existing pod-annotation escape hatch or `kubectl rollout restart`; Helm cannot hash external data it does not own reliably offline.

**Risks/dependencies:** No change to external ConfigMap ownership or mount path.

**Acceptance/validation:** Changing one runtime key changes Deployment pod template and served `/config.js`; unchanged config preserves checksum; external ConfigMap behavior is explicit.

### F-07 — P1 — Empty web configuration silently falls back to image-build endpoints

**Evidence:** Chart defaults all four runtime keys to empty (`permesi-helm/charts/web/values.yaml:39-42`); helper validates only the ConfigMap key (`templates/_helpers.tpl:55-59`). Application discards empty overrides (`permesi/apps/web/src/lib/config.rs:96-103`); release build defaults to production `.com` endpoints (`.github/workflows/deploy.yml:299-309`).

**Impact:** A newly installed console can contact the image’s baked environment instead of the installed stack. Backend OPAQUE defaults also differ from published-web build defaults.

**Minimal solution:** For chart-managed ConfigMaps, require nonblank values for the four existing runtime fields. Document explicit external-ConfigMap responsibility. Require a provisioned Genesis client and matching OPAQUE ID; do not invent credentials or derive browser URLs from cluster-local Service names.

**Risks/dependencies:** This intentionally makes formerly ambiguous empty configurations fail early. Update CI fixtures and document the upgrade requirement.

**Acceptance/validation:** Empty/whitespace managed config fails rendering; valid config renders safely through `toJson`; a browser network trace contains only the intended API/Genesis hosts.

### F-08 — P1 — Backend termination grace is shorter than the application shutdown budget

**Evidence:** Both charts default `terminationGracePeriodSeconds: 30` (`permesi-helm/charts/permesi/values.yaml:180`, Genesis `:148`). Application request drain alone permits 30 seconds (`permesi/crates/service_utils/src/shutdown.rs:21`), followed by Permesi worker shutdown up to 10 seconds (`services/permesi/src/api/mod.rs:220-235`) and pool closure up to 5 seconds (`crates/service_utils/src/database.rs:48,190-199`), plus telemetry flush.

**Minimal solution:** Set backend default grace to 60 seconds and document the budget. Preserve operator overrides. Do not add shell-based sleep hooks to scratch images or blindly add preStop delay.

**Risks/dependencies:** Longer node drains; sidecars must also terminate within pod grace.

**Acceptance/validation:** Under in-flight requests and pending email work, SIGTERM finishes without SIGKILL within configured grace. Fail-closed shutdown remains an error exit and replacement pods recover.

### F-09 — P1 — Production examples omit operationally important supported settings

**Evidence:** Chart examples configure older core values but omit SMTP, OIDC enablement, and trusted proxy CIDRs (`permesi-helm/charts/permesi/README.md:30-54`, root `README.md:57-101`). Source defaults email to outbox (`permesi/services/permesi/src/cli/commands/mod.rs:39-44`), makes OIDC issuer/audience opt-in (`:294-301`), and trusts client-IP headers only from configured peers (`api/handlers/auth/operations.rs:183-213`).

**Impact:** A superficially healthy installation may not deliver verification email or expose an enabled OIDC authority. Behind an ingress, unconfigured client-IP trust can combine users into proxy-IP rate-limit buckets.

**Minimal solution:** Extend production examples using `extraEnv` and Secret references for SMTP password. Document:
- Explicit SMTP versus intentional outbox operation.
- Paired OIDC issuer/audience and separate OIDC signing key.
- Matching frontend URL/CORS, passkey origins, and web OPAQUE ID.
- Narrow ingress proxy CIDRs and required header overwriting.
- Pool connection budgets and maximum replicas.

**Risks/dependencies:** Never trust `0.0.0.0/0` merely to restore client-IP behavior. OIDC/SMTP need corresponding infrastructure.

**Acceptance/validation:** Signup delivers email; code/PKCE/OIDC flow succeeds; client IPs are separated through the ingress and spoofed headers from untrusted peers are ignored.

### F-10 — P1 — Default pods do not satisfy Restricted Pod Security seccomp requirements

**Evidence:** All three charts specify nonroot UID, dropped capabilities, and no privilege escalation, but omit seccomp from both security contexts (`permesi-helm/charts/{permesi,genesis,web}/values.yaml:22-34`). Backend scratch images and static frontend do not establish a requirement for an unconfined profile (`permesi/services/{permesi,genesis}/Dockerfile:24-34`, `apps/web/Dockerfile:1-6`).

**Minimal solution:** Default pod `seccompProfile.type` to `RuntimeDefault`, retaining overrides. Also render `automountServiceAccountToken` at pod scope from the existing value so it applies when `serviceAccount.create=false`.

**Risks/dependencies:** Backend token automount should not be blindly disabled: an externally injected Kubernetes-auth Vault Agent may require it. Test injected pods, not just the application container.

**Acceptance/validation:** All configured workloads are admitted in a Restricted namespace and run. External-service-account mode honors the chosen automount setting.

### F-11 — P1 — CI installation fixtures do not exercise application pods or stack integration

**Evidence:** All three component `ci/ct-values.yaml:2` set replicas to zero. Stack CI values disable every dependency. `charts-ci.yml` runs ct, but has no runtime contract tests; changed-chart detection suppresses command failure with `|| true` at line 69. Source requires real TLS/Vault/DB initialization, which zero replicas never exercise. `publish-charts.yml:79` also suppresses dependency-build failure.

**Minimal solution:**
1. Keep render-only fixtures clearly identified.
2. Run one real web replica with valid runtime config.
3. Add deterministic render assertions for the identified contracts and negative validation cases.
4. Add a separate real-dependency backend/stack integration job.
5. Stop swallowing changed-chart detection and dependency-build failures.

**Risks/dependencies:** A Kind install with zero backend replicas is not an end-to-end test. Backend integration requires provisioned schemas, Vault roles/keys, and certificates.

**Acceptance/validation:** A deliberately wrong env name, missing TLS mount, unused ESO target, missing web checksum, and invalid backend startup each fail an appropriate gate. Dependency build failure blocks publishing.

### F-12 — P2 — NetworkPolicy controls are correct but lack runnable allow-list examples

**Evidence:** All charts render both Ingress and Egress policies and default empty lists when enabled (`permesi-helm/charts/*/templates/networkpolicy.yaml:13-26`). Application dependencies include PostgreSQL, Vault, Genesis PASERK, optional SMTP/OTLP; web dependencies execute in the browser, not nginx.

**Minimal solution:** Document deny-all behavior and provide environment-specific allow-list examples covering DNS and the actual server-side calls. Do not turn policy on globally without complete rules or replace raw rules with a speculative policy abstraction.

**Acceptance/validation:** On a network-policy-enforcing CNI, required traffic succeeds and unauthorized ingress/egress fails. Web pod egress is not opened unnecessarily to API/Genesis.

### F-13 — P2 — Targeted schema and release/runbook improvements

**Evidence:** Schemas leave probes and several operational fields weakly constrained; HPA minimum/maximum relationship is unchecked. Root install examples still say `0.3.29` (`permesi-helm/README.md:31,38-40`) although charts are `0.4.3`. `scripts/bump-release.sh:22-27,45-56` intentionally couples chart/app/image version updates for application releases, while publish validation checks chart versions only (`publish-charts.yml:46-60`).

**Minimal solution:**
- Add targeted checks for invalid HPA bounds, invalid grace/probe values, and ESO configuration.
- Document one-replica PDB implications rather than forbidding valid `minAvailable: 1`.
- Refresh release examples.
- Document chart-only release procedure: bump synchronized chart/dependency versions while retaining application/image versions. Do not use the app-release bump script for that operation.

**Important rejected claim:** “Chart-only releases are impossible” is not supported. They are possible by changing chart/dependency versions independently; the current automation simply lacks a dedicated documented path.

**Acceptance/validation:** Invalid operational combinations fail predictably; application-release bumps retain alignment; a chart-only bump leaves image references unchanged.

## 4. Milestones with non-overlapping file ownership

Shared contracts:

- Preserve all existing values keys and explicit resource names.
- ESO effective-name precedence: explicit target first; generated default only when that ESO source is enabled.
- Web managed runtime fields must be nonblank; external ConfigMap remains user-owned.
- Backend grace defaults to 60 seconds.
- Production examples use E for additional application options rather than adding dozens of redundant values.
- No application-repository edits.

### M1 — Permesi chart correctness and operational contract — P1

**Files exclusively owned:**

`permesi-helm/charts/permesi/values.yaml`  
`permesi-helm/charts/permesi/values.schema.json`  
`permesi-helm/charts/permesi/templates/_helpers.tpl`  
`permesi-helm/charts/permesi/templates/deployment.yaml`  
`permesi-helm/charts/permesi/templates/external-secret.yaml`  
`permesi-helm/charts/permesi/templates/NOTES.txt`  
`permesi-helm/charts/permesi/README.md`  
`permesi-helm/charts/permesi/ci/ct-values.yaml`

**Steps:** Fix effective-secret resolution/validation; update grace and seccomp/pod automount; correct Vault URL documentation; document restart-safe auth and runtime options; update fixture values. Addresses F-01–F-05, F-08–F-10, relevant F-13.

### M2 — Genesis chart correctness and operational contract — P1

Same explicit file set under `permesi-helm/charts/genesis/`, excluding nothing except that Genesis has no admission-CA handling.

**Steps:** Mirror agreed ESO contract; preserve Genesis base-URL semantics and `GENESIS_TRANSIT_MOUNT`; update grace/seccomp/pod automount; document admission env, restart-safe auth, TLS and DB prerequisites. Addresses F-02/F-03/F-05/F-08/F-10.

M1 and M2 can run in parallel.

### M3 — Web runtime correctness — P1

**Files exclusively owned:**

`permesi-helm/charts/web/values.yaml`  
`permesi-helm/charts/web/values.schema.json`  
`permesi-helm/charts/web/templates/_helpers.tpl`  
`permesi-helm/charts/web/templates/deployment.yaml`  
`permesi-helm/charts/web/templates/configmap-runtime.yaml`  
`permesi-helm/charts/web/templates/NOTES.txt`  
`permesi-helm/charts/web/README.md`  
`permesi-helm/charts/web/ci/ct-values.yaml`

**Steps:** Validate nonblank managed runtime fields; checksum managed configuration; preserve external ConfigMap path; set seccomp/pod automount; run a real CI web replica with valid config. Addresses F-06/F-07/F-10 and part of F-11.

### M4 — Stack integration profile and production runbook — P1/P2

**Files exclusively owned:**

`permesi-helm/charts/permesi-stack/values.yaml`  
`permesi-helm/charts/permesi-stack/README.md`  
`permesi-helm/charts/permesi-stack/ci/ct-values.yaml`  
`permesi-helm/README.md`  
New `permesi-helm/docs/examples/production-stack.yaml`  
New `permesi-helm/docs/operations.md`

**Steps:** Create an internally consistent release/namespace/service/TLS profile; document prerequisites, schema upgrades, SMTP/OIDC/proxies, trust boundaries, restart recovery, NetworkPolicy rules, external ConfigMap/Secret rotation, and rollback limits. Do not change fullname defaults. Addresses F-02/F-04/F-05/F-09/F-12/F-13.

Can proceed alongside M1–M3 using the shared contracts.

### M5 — Contract tests and real-dependency CI — P1

**Files exclusively owned:**

`permesi-helm/.github/workflows/charts-ci.yml`  
`permesi-helm/.github/workflows/publish-charts.yml`  
`permesi-helm/.ct.yaml`  
New `permesi-helm/scripts/check-runtime-contracts.py`  
New `permesi-helm/scripts/integration-stack.sh`

**Steps:** Fail on tooling errors; add render assertions and negative cases; add real web smoke installation; add isolated PostgreSQL/Vault/TLS integration setup and scenarios. Consume chart fixtures owned by M1–M4 without editing them. Addresses F-11.

Integrate after chart contract changes land. Run verification once after all slices are integrated.

**Release metadata:** One integration owner handles any required coordinated `Chart.yaml`/dependency-version changes after these slices. Do not have independent builders run the release bump script concurrently.

## 5. Validation plan

### Static and render gates

Run from `permesi-helm/`, using containerized tooling where necessary:

```sh
helm lint charts/permesi --strict -f charts/permesi/ci/ct-values.yaml
helm lint charts/genesis --strict -f charts/genesis/ci/ct-values.yaml
helm lint charts/web --strict -f charts/web/ci/ct-values.yaml

helm dependency build charts/permesi-stack
helm lint charts/permesi-stack --strict \
  -f charts/permesi-stack/ci/ct-values.yaml

python3 scripts/check-runtime-contracts.py
ct lint --all --config .ct.yaml
```

Containerized Helm example:

```sh
podman run --rm \
  -v /home/devops/projects/permesi/permesi-helm:/w:Z \
  -w /w quay.io/helmpack/chart-testing:v3.13.0 \
  helm template assessment charts/permesi \
  -f charts/permesi/ci/ct-values.yaml
```

The contract suite should assert:

- Exact env names, quoted values, Secret references, and TLS/CA paths.
- TCP versus socket exclusivity and absence of socket-mode Service/probes.
- ESO generated targets equal Deployment consumers.
- Invalid store/name/auth combinations fail.
- Managed web empty runtime values fail.
- Runtime changes alter web checksum.
- Explicit existingConfigMap remains supported.
- HPA mode omits Deployment replicas and targets the correct Deployment.
- PDB/selectors remain stable.
- Service target ports and ingress backends agree.
- Release/namespace/name overrides are reflected in the documented admission endpoint.
- Security contexts and pod-level automount render correctly.
- Valid previous explicit values remain accepted.

### Kind/ct smoke

```sh
ct install --all --config .ct.yaml
bash scripts/integration-stack.sh
```

Use a Restricted namespace and a CNI that actually enforces NetworkPolicy for policy tests. A default Kind installation alone is insufficient evidence of policy enforcement.

Web smoke must fetch `/healthz`, `/config.js`, index and WASM assets, then upgrade only runtime config and verify the new values are served.

### Scenarios requiring real PostgreSQL and Vault

1. Two backend replicas start with provisioned schemas and least-privilege dynamic DB roles.
2. Direct Permesi AppRole full endpoint works; the documented negative base-origin case fails.
3. Agent mode starts with an accessible socket; restart/scale-out reacquires usable credentials.
4. Shared one-use SecretID/wrapped-token failure is demonstrated and excluded from HA examples.
5. DB lease expiry/revocation causes the expected fail-closed recovery.
6. Genesis signs admission tokens; Permesi verifies using `/paserk.json`; wrong issuer/audience and invalid signatures fail.
7. Genesis key rotation and outage affect readiness as documented without dependency-based liveness restart loops.
8. OIDC discovery and `/jwks.json` use the separate OIDC key; authorization/code/PKCE flow works.
9. Correct private CAs succeed; wrong CA/SAN fails; backend certificate Secret rotation reloads.
10. PostgreSQL TLS is verified, and schema-before-rollout procedure is exercised on existing data.
11. SMTP delivery works with Secret-sourced credentials.
12. SIGTERM during active requests/email work completes inside the new grace period.
13. Trusted proxy configuration separates client rate limits and rejects spoofed direct headers.
14. NetworkPolicy allows only documented paths.
15. Helm upgrade preserves selectors/resource names and external data; rollback limits are explicit.

### Evidence actually collected

- Source, templates, values, schemas, Dockerfiles, relevant workflows, CI fixtures, and documentation were inspected.
- `git status --short --branch` showed clean application `sandbox` and chart `feat/helm-hardening` working trees.
- No Helm render, lint, build, test, container smoke, or cluster installation was executed.
- Published image bytes, inherited nginx image details, and live external infrastructure remain unverified.

## 6. Out of scope and rejected ideas

- **No application edits.** A separate source issue exists in `permesi/apps/web/nginx.conf:31-34,46-83`: location-level `add_header` directives prevent inheritance of server-level security headers under nginx’s normal inheritance rules. This is not repaired by altering chart values; validate against the resolved image and address in the application repository separately.
- No bundled PostgreSQL/Vault or application PVC: persistence is external by design.
- No automatic Helm migration hooks: schema changes require owner privileges and explicit upgrade ordering.
- No application-native Kubernetes auth redesign: use the existing agent boundary.
- No shared admission signing Secret: Genesis retains signing authority; Permesi receives public PASERK only.
- No removal of useful extension points or addition of dedicated values for every optional env variable.
- No default Service renaming to make hard-coded DNS happen to match.
- No sticky sessions as an assumed HA fix; current source contains shared PostgreSQL-backed authentication state.
- No dependency-based liveness probe or claim that `/health` checks all Vault operations.
- No automatic enablement of deny-all policies without tested allow rules.
- No shell lifecycle hooks in scratch images.
- No claim that UID `10001` versus image UID `65532` is itself a defect.
- No claim that chart-only releases are impossible, or that absent explicit RollingUpdate configuration means recreate deployments.
- Digest pinning and broader release-automation redesign are optional follow-on work, not prerequisites for the confirmed fixes.

---

### Main-agent delivery summary

**P0:** none established for a correctly configured deployment.

**P1:** F-01 Vault login URL; F-02 one-use credential/replica lifecycle; F-03 ESO target wiring; F-04 admission discovery; F-05 TLS/database/schema prerequisites; F-06 stale web runtime config on upgrade; F-07 baked-environment fallback; F-08 insufficient termination grace; F-09 incomplete production runtime examples; F-10 Restricted seccomp compatibility; F-11 ineffective runtime/integration CI.

**Milestones:** M1 Permesi chart; M2 Genesis chart; M3 web runtime; M4 stack/profile/runbook; M5 contract tests and real-dependency CI. Main must create the requested Markdown file from this handoff before claiming the file-existence acceptance criterion is satisfied.

---

## 7. Lead plan review (Opus)

Spot-verified before approval: F-01 (`permesi/crates/vault_client/src/lib.rs` `approle_login` POSTs to the supplied URL; Genesis alone normalizes via `services/genesis/src/vault/mod.rs:21`), F-03 (vault ExternalSecret target derives from `vault.roleId.existingSecret` while the Deployment reads `vault.secretId.existingSecret` separately; default ESO targets are never consumed), F-08/F-10 (values defaults).

| Finding | Decision | Notes |
|---|---|---|
| F-01 | Approved (docs/NOTES) | No URL rewriting in templates. |
| F-02 | Approved (docs only) | Restart-safe auth documented; no new auth mechanism. |
| F-03 | Approved | Effective-name helpers; explicit names keep precedence; fail on conflicting Vault target names or missing store. |
| F-04 | Approved, narrowed | No default changes/renames. Production example + umbrella NOTES warning computing the real Genesis Service. |
| F-05, F-09, F-12 | Approved (docs/example) | `docs/operations.md`, `docs/examples/production-stack.yaml`, chart READMEs. |
| F-06 | Approved | Checksum annotation for chart-managed web config. |
| F-07 | Approved with escape hatch | Fail on blank managed runtime keys; new `runtimeConfig.allowBuildDefaults` (default `false`) restores previous fallback behavior for upgrades. |
| F-08 | Approved | Backend grace 60 s. |
| F-10 | Approved | `seccompProfile: RuntimeDefault`; pod-level `automountServiceAccountToken` (defaults unchanged). |
| F-11 | Approved, narrowed | helm-unittest suites per chart, CI runs them, stop swallowing tool failures, one real web replica in ct install. Real Postgres/Vault/TLS integration job **deferred**: needs provisioned schemas, Vault roles/transit keys and certificates; tracked as outstanding. |
| F-13 | Approved (subset) | HPA bounds validation, `.helmignore`, stale README versions, chart-only release note. |

Milestones executed: M1 permesi chart, M2 genesis chart, M3 web chart, M4 stack/docs, M5 CI — disjoint file sets, separate worktrees, integrated by the lead.

## 8. Implementation status and outstanding verification

| Finding | Status | Where |
|---|---|---|
| F-01 | Done | `charts/permesi/{README.md,templates/NOTES.txt}`, root `README.md`, `docs/operations.md` |
| F-02 | Done (docs) | `docs/operations.md` §2, chart READMEs/NOTES |
| F-03 | Done | `charts/{permesi,genesis}/templates/{_helpers.tpl,deployment.yaml,external-secret.yaml}` + tests |
| F-04 | Done (profile + umbrella NOTES warning) | `docs/examples/production-stack.yaml`, `charts/permesi-stack/templates/NOTES.txt` |
| F-05, F-09, F-12 | Done (docs/example) | `docs/operations.md`, `docs/examples/production-stack.yaml` |
| F-06, F-07 | Done | `charts/web/templates/*`, `runtimeConfig.allowBuildDefaults` |
| F-08, F-10 | Done | backend grace 60 s; `seccompProfile: RuntimeDefault`; pod-level `automountServiceAccountToken` |
| F-11 | Partly done | helm-unittest suites (55 tests), CI runs them with Helm pinned to v3.16.4, production-profile render gate, failures no longer swallowed, one real web replica in `ct install`. |
| F-13 | Partly done | HPA bounds validation, `.helmignore`, README versions, chart-only release note. |

Chart versions bumped to 0.4.4 (chart-only); `appVersion` and image tags stay 0.4.3. The next application release must use a version above 0.4.4 or bump charts past it, because `ct` enforces version increments.

**Not yet verified (needs an isolated environment with real dependencies):**

- Backend pods running against real PostgreSQL, Vault (AppRole and Agent socket modes), and TLS certificates. The Kind checks only proved admission under the Restricted Pod Security Standard and the rendered pod spec; without dependencies the backends cannot become ready.
- Genesis→Permesi PASERK fetch over cluster TLS, admission-token verification, and OIDC flow.
- External Secrets Operator reconciliation against a real store.
- NetworkPolicy enforcement, which needs a CNI that enforces it; Kind's default CNI does not.
- Certificate rotation, SIGTERM drain under load, and DB credential lease expiry.
- GitHub Actions execution of the modified workflows.
