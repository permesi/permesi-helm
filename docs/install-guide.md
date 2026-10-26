# Permesi installation guide

Step-by-step manual guide for running the Permesi platform on Kubernetes.

Two paths are documented here:

- **Production** — externally operated PostgreSQL and Vault, chart-managed Vault
  Agent (Kubernetes auth + PKI certificate rendering). Recommended. Legacy
  AppRole/Secret and External Secrets Operator (ESO) paths remain supported but
  are not the primary walkthrough (§3 explains the URL difference).
- **Disposable quickstart** — `scripts/quickstart/install.sh`, one command,
  cluster-local PostgreSQL + dev-mode Vault. Development only.

This guide follows the design contract in
`docs/engineering/k8s-adoption-plan.md` §10. Placeholder hostnames use the same
release/namespace (`permesi`/`permesi`) and public DNS as
`docs/examples/production-stack.yaml`; substitute your own.

---

## 1. Cluster, architecture and least-required RBAC

### Supported versions

- Any Kubernetes cluster that can run the charts (Helm 3.13+).
- **Vault Agent mode** (`vault.agent.enabled: true`) requires
  **Kubernetes ≥ 1.29 with the `SidecarContainers` feature gate enabled**, because
  the Agent is a native sidecar (`initContainers[].restartPolicy: Always`) that
  must outlive the application container during graceful shutdown. Recommend
  **≥ 1.33**, where native sidecars are stable. This opt-in mode fails chart
  rendering on an older API server; disabled mode (the default) has no such
  requirement.
- Application images are `linux/amd64` (`ghcr.io/permesi/{permesi,genesis,web}:0.4.3`).
  Use an amd64 node, or separately verified images.

### Architecture

| Component | Role |
|---|---|
| `permesi` | IAM service (Deployment/Service/Ingress/HPA/PDB/NetworkPolicy) |
| `genesis` | edge admission service (same operational patterns) |
| `web` | nginx-served UI; `/config.js` injected at runtime |
| `permesi-stack` | umbrella chart installing all three |

Backend containers are `scratch` images (no shell). The Vault Agent sidecar is the
only place shell probes, certificate rendering, and preparation happen.

### Least-required RBAC

- **Application ServiceAccounts need no RBAC.** They need no Secret read/list and
  no TokenReview permission; Vault authenticates the pod via the projected
  service-account token, and the Agent holds the resulting Vault token. In Agent
  mode the chart sets `serviceAccount.automount=false` and mounts a projected,
  audience-scoped token **only into the Agent container**.
- **In-cluster Vault** needs `TokenReview` for its *own* ServiceAccount only — a
  narrowly scoped ClusterRole, or the upstream `system:auth-delegator` cluster role
  bound to Vault's SA alone. Do not grant TokenReview to backend or bootstrap
  ServiceAccounts.
- **External Vault** needs operator-managed API/CA connectivity and a *renewable*
  Kubernetes reviewer token (a long-lived service-account token the operator
  rotates on a documented schedule), plus its Kubernetes auth config pointed at
  the cluster API server.
- **Operators** need permission to create the namespace, ServiceAccounts, Secrets
  (legacy paths only), ConfigMaps (public trust anchors), and to write Vault
  policies/roles via the Vault API.

---

## 2. PostgreSQL: databases, owners, runtime grants

Both services require externally provisioned databases. There is no bundled
database, no PVC, and **no application migrations**: schemas are applied by an
operator as the schema owner before the pods start.

### Version compatibility

Application CI runs against official **PostgreSQL 18**. Production requires a
pg_cron-capable deployment if you use the canonical scheduled jobs (`cron_jobs.sql`
+ `check.sql`); stock PostgreSQL does not provide pg_cron.

### Ownership model

- `vault_permesi` / `vault_genesis`: non-superuser roles used by Vault's database
  secrets engine. They must have `LOGIN`, `CREATEROLE`, and `pg_signal_backend`
  (to terminate sessions on lease revocation). They own their respective database.
- `permesi_runtime` / `genesis_runtime`: `NOLOGIN` roles that hold all
  schema/table grants. Vault-minted short-lived login roles receive membership in
  the matching runtime role only — they never own objects, create schemas, or hold
  superuser privileges.
- Vault's database roles use `CREATE ROLE ... LOGIN ... VALID UNTIL` (creation),
  `ALTER ROLE ... VALID UNTIL` (renewal), and terminate-sessions → revoke-membership
  → drop-role (revocation). Default TTL 1h / max 4h.

### 2.1 Pre-create the Vault manager roles

Create the two Vault manager roles with strong, unique passwords **before** running
the canonical bootstrap, so `00_init.sql` does not fall back to its development
`change-me` password:

```bash
psql -h db.example.com -U postgres -d postgres \
  -c "CREATE ROLE vault_permesi WITH LOGIN PASSWORD '<strong-password>' CREATEROLE;"
psql -h db.example.com -U postgres -d postgres \
  -c "CREATE ROLE vault_genesis WITH LOGIN PASSWORD '<strong-password>' CREATEROLE;"
psql -h db.example.com -U postgres -d postgres \
  -c "GRANT pg_signal_backend TO vault_permesi, vault_genesis;"
```

### 2.2 Apply the canonical include tree

Run `00_init.sql` once as a superuser with `ON_ERROR_STOP=1`. It creates the two
databases (owned by the Vault roles), the runtime roles, transfers object
ownership, and then reconnects as each authenticated owner to load
`01_genesis.sql`, `02_permesi.sql`, `seed_test_client.sql`, and
`verify_permesi.sql`. Do **not** independently reapply the three files as an
administrator or substitute `SET ROLE` — the script switches to fresh
owner-authenticated connections.

```bash
export PGPASSWORD='<admin-password>'
# .pgpass must also carry the vault_permesi / vault_genesis credentials so the
# script's `\connect <db> <owner>` steps can authenticate over TCP.
psql -h db.example.com -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f db/sql/00_init.sql
unset PGPASSWORD
```

A minimal `.pgpass` (mode `0600`) for the owner-authenticated connections:

```
db.example.com:5432:*:vault_permesi:<strong-password>
db.example.com:5432:*:vault_genesis:<strong-password>
```

### 2.3 Production scheduler (pg_cron) and verification

On a pg_cron-capable PostgreSQL, register the scheduled jobs and run the full
verification (both against `postgres`):

```bash
psql -h db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 -f db/sql/cron_jobs.sql
psql -h db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 -f db/sql/check.sql
```

`verify_permesi.sql` (already run by `00_init.sql`) is the schema smoke check.
`check.sql` additionally requires pg_cron and both registered jobs; do not claim
`check.sql` passed on a scheduler-less deployment.

### 2.4 Schema upgrades and OAuth reapplication

Reapply the additive scripts (`02_permesi.sql` for the OAuth/refresh/credential
tables) as the existing schema owner with `ON_ERROR_STOP=1` **before** starting a
binary that exposes the new protocol routes. Reapplication preserves client
configuration, grants, and data. Helm rollback does **not** roll back schema or
data. Never run `reset_all.sql` outside dev/test.

### 2.5 PostgreSQL TLS

Use `sslmode=verify-full` plus a CA file mounted via `extraVolumes`/`extraVolumeMounts`
(see the production example). Vault's database connection URL must also use
`sslmode=verify-full` (or `verify-ca`) in production, with Vault configured to
trust the database CA.

---

## 3. Vault: reviewer, auth roles, mounts, policies, PKI

This section translates `vault/contrib/terraform/*.tf` into concrete Vault CLI
steps for an operator. Set the environment first:

```bash
export VAULT_ADDR="https://vault.example.com:8200"
export VAULT_TOKEN="<root-or-admin-token>"
# Only if Vault uses a private CA:
export VAULT_CACERT="/path/to/vault-ca.pem"
```

Keep TLS verification enabled. The PKI issuing/CRL URLs must be routable
(`https://vault.example.com/v1/pki-int/ca`, `.../crl`).

### 3.1 Kubernetes auth and reviewer configuration

```bash
vault auth enable kubernetes
```

**In-cluster Vault** — point Vault at the cluster and let it re-read its own
service-account token (do not persist an expiring `kubectl create token` result):

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```

Grant TokenReview to **Vault's SA only**:

```bash
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault
```

**External Vault** — write a renewable long-lived reviewer token and rotate it on
a documented schedule; configure `kubernetes_host` to a reachable API/CA endpoint.

### 3.2 Kubernetes auth roles (SA-bound, exact namespace/audience)

Bind distinct roles to the *actual rendered* ServiceAccount names and one exact
namespace. Audience must be `vault` (the value used by the chart's projected
token). No wildcard namespaces/accounts:

```bash
vault write auth/kubernetes/role/permesi \
  bound_service_account_names="permesi" \
  bound_service_account_namespaces="permesi" \
  audience="vault" \
  token_policies="permesi" \
  token_ttl="1h" \
  token_max_ttl="4h"

vault write auth/kubernetes/role/genesis \
  bound_service_account_names="permesi-genesis" \
  bound_service_account_namespaces="permesi" \
  audience="vault" \
  token_policies="genesis" \
  token_ttl="1h" \
  token_max_ttl="4h"
```

> The ServiceAccount names are release-dependent: a release named `permesi`
> renders `permesi` (permesi chart) and `permesi-genesis` (genesis chart). Adjust
> to your `fullnameOverride`/`nameOverride`. These are renewable service tokens
> (TTL 1h / max TTL 4h), so Agent restart and JWT rotation are covered.

### 3.3 KV v2 seed/pepper (cryptographic identity)

Mount KV v2 and write the 32-byte standard-base64 seed/pepper **only if absent**.
If the config is partially populated, stop rather than silently replace
cryptographic identity — a fresh seed makes existing users unrecoverable:

```bash
vault secrets enable -path=secret/permesi -version=2 kv

vault kv get secret/permesi/config >/dev/null 2>&1 || \
vault kv put secret/permesi/config \
  opaque_server_seed="$(openssl rand 32 | base64 -w0)" \
  mfa_recovery_pepper="$(openssl rand 32 | base64 -w0)"
```

### 3.4 Transit mounts and keys

```bash
vault secrets enable -path=transit/permesi transit
vault secrets enable -path=transit/genesis transit

vault write -f transit/permesi/keys/totp \
  type=chacha20-poly1305 auto_rotate_period=2592000
vault write -f transit/genesis/keys/genesis-signing \
  type=ed25519 auto_rotate_period=2592000

# OIDC signing — only when OIDC is enabled. Separate from TOTP and admission keys.
vault write -f transit/permesi/keys/oidc-signing \
  type=rsa-2048 exportable=false allow_plaintext_backup=false \
  deletion_allowed=false auto_rotate_period=2592000
```

### 3.5 Database secrets engine

```bash
vault secrets enable database

vault write database/config/permesi \
  plugin_name=postgresql-database-plugin \
  allowed_roles="permesi" \
  connection_url="postgresql://{{username}}:{{password}}@db.example.com:5432/permesi?sslmode=verify-full" \
  username="vault_permesi" \
  password="<vault_permesi-password>" \
  max_connection_lifetime="120" \
  root_rotation_statements='ALTER ROLE "{{username}}" WITH PASSWORD '"'"'{{password}}'"'"';'

vault write database/roles/permesi \
  db_name="permesi" \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT permesi_runtime TO "{{name}}";' \
  renew_statements='ALTER ROLE "{{name}}" WITH VALID UNTIL '"'"'{{expiration}}'"'"';' \
  revocation_statements='SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.usename = '"'"'{{name}}'"'"'; REVOKE permesi_runtime FROM "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' \
  default_ttl="1h" \
  max_ttl="4h"
```

Repeat for `genesis` with `database/config/genesis`, `database/roles/genesis`, the
`genesis` database name, and `GRANT genesis_runtime`. Each connection's
`allowed_roles` is restricted to itself.

> The application always replaces DSN username/password with Vault-issued
> credentials from `/v1/database/creds/{permesi,genesis}`; the DSN Secret carries
> a placeholder username/password — only host/port/database and TLS options matter.

### 3.6 PKI hierarchy

```bash
vault secrets enable -path=pki-root -max-lease-ttl=315360000 pki
vault secrets enable -path=pki-int  -max-lease-ttl=94608000  pki

# Root CA (offline issuer)
vault write -field=certificate pki-root/root/generate/internal \
  common_name="Permesi Root CA" ttl=87600h key_type=ec key_bits=256 \
  issuer_name=permesi-root > pki-root.crt

# Intermediate: generate CSR, sign, set-signed
vault write -field=csr pki-int/intermediate/generate/internal \
  common_name="Permesi Intermediate CA" key_type=ec key_bits=256 > pki-int.csr
vault write -field=certificate pki-root/root/sign-intermediate \
  csr=@pki-int.csr common_name="Permesi Intermediate CA" ttl=26280h \
  format=pem_bundle > pki-int.crt
vault write pki-int/intermediate/set-signed certificate=@pki-int.crt

# Issuing/CRL URLs
vault write pki-root/config/urls \
  issuing_certificates="https://vault.example.com/v1/pki-root/ca" \
  crl_distribution_points="https://vault.example.com/v1/pki-root/crl"
vault write pki-int/config/urls \
  issuing_certificates="https://vault.example.com/v1/pki-int/ca" \
  crl_distribution_points="https://vault.example.com/v1/pki-int/crl"
```

Import the complete signed issuer chain at `intermediate/set-signed`, including
each parent intermediate. The Agent writes the ordered, deduplicated
`pkiCert` `.Data.CAChain` after the leaf; it cannot reconstruct a chain missing
from Vault's issuance response. A self-signed root is included in the bundle if
Vault returns it. Verify the leaf against your independently trusted root, not
against a CA accepted solely because it arrived in the bundle.

### 3.7 PKI runtime roles (service-scoped SANs)

ServerAuth suffices for these listener certificates. `allowed_domains` lists the
exact service and public passthrough DNS names; subdomain/glob/wildcard/any-name/IP
issuance is disabled:

```bash
vault write pki-int/roles/permesi-runtime \
  allowed_domains="permesi.permesi.svc.cluster.local,api.permesi.example.com" \
  allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
  allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true \
  allow_ip_sans=false \
  key_type=ec key_bits=256 \
  key_usage="DigitalSignature,KeyAgreement" ext_key_usage="ClientAuth,ServerAuth" \
  ttl="24h" max_ttl="72h"

vault write pki-int/roles/genesis-runtime \
  allowed_domains="permesi-genesis.permesi.svc.cluster.local,genesis.permesi.example.com" \
  allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
  allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true \
  allow_ip_sans=false \
  key_type=ec key_bits=256 \
  key_usage="DigitalSignature,KeyAgreement" ext_key_usage="ClientAuth,ServerAuth" \
  ttl="24h" max_ttl="72h"
```

The production root CA lifecycle stays operator-managed; keep the root offline and
rotate the intermediate before the TTL elapses.

### 3.8 Policies

Write the per-service policies from the §3 contract. Each combines the common
workload permissions, that service's runtime permissions, and its PKI issue path.
The Agent token gets this single policy per pod.

`permesi-policy.hcl`:

```hcl
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "sys/leases/renew"       { capabilities = ["update"] }

path "database/creds/permesi"       { capabilities = ["read"] }
path "secret/permesi/data/config"   { capabilities = ["read"] }
path "transit/permesi/datakey/plaintext/totp" { capabilities = ["update"] }
path "transit/permesi/decrypt/totp" { capabilities = ["update"] }

path "pki-int/issue/permesi-runtime" { capabilities = ["create", "update"] }
path "pki-int/cert/ca_chain"         { capabilities = ["read"] }

# OIDC enabled only
path "transit/permesi/keys/oidc-signing" { capabilities = ["read"] }
path "transit/permesi/sign/oidc-signing" { capabilities = ["update"] }
```

`genesis-policy.hcl`:

```hcl
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "sys/leases/renew"       { capabilities = ["update"] }

path "database/creds/genesis"                  { capabilities = ["read"] }
path "transit/genesis/keys/genesis-signing"    { capabilities = ["read"] }
path "transit/genesis/sign/genesis-signing"    { capabilities = ["update"] }

path "pki-int/issue/genesis-runtime" { capabilities = ["create", "update"] }
```

> Note `pki-int/cert/ca_chain` (Permesi PASERK CA) is the **authenticated JSON**
> endpoint, not the raw-PEM `pki-int/ca` or `pki-int/ca_chain` endpoint. The Agent
> renders the Permesi PASERK CA from `secret "pki-int/cert/ca_chain"`.

```bash
vault policy write permesi permesi-policy.hcl
vault policy write genesis genesis-policy.hcl
```

### 3.9 Optional: legacy AppRole path

The Agent path is recommended. The legacy AppRole path is still supported for
backward compatibility — but note the **URL difference**:

- **Permesi 0.4.3** POSTs the role/secret ID to `vault.url` verbatim, so it must be
  the full login endpoint `https://vault.example.com:8200/v1/auth/approle/login`.
- **Permesi ≥ next release** (app branch `feat/k8s-hardening`, unreleased) accepts a
  Vault base URL (`https://vault.example.com:8200`) and normalizes it.
- Genesis already accepts either form.

```bash
vault auth enable approle
vault write auth/approle/role/permesi \
  token_policies="permesi" token_no_default_policy=true \
  token_ttl=1h token_max_ttl=4h secret_id_num_uses=1 secret_id_ttl=1h bind_secret_id=true
vault write auth/approle/role/genesis \
  token_policies="genesis" token_no_default_policy=true \
  token_ttl=1h token_max_ttl=4h secret_id_num_uses=1 secret_id_ttl=1h bind_secret_id=true
```

AppRole SecretIDs are single-use with a 1-hour TTL by default: use Agent mode for
multi-replica, restart-safe deployments, or provision SecretIDs with sufficient
uses/TTL and a rotation procedure.

---

## 4. Agent values, volumes, startup gate, HTTPS

### 4.1 Values

The `vault.agent.*` block is additive and defaults to disabled. When enabled, the
chart renders a native sidecar running the official `hashicorp/vault` image with
Kubernetes auto-auth, a local Unix socket proxy (`use_auto_auth_token = true`, no
cache), and PKI templates that render the TLS bundle and (for Permesi) the PASERK CA.

```yaml
permesi:
  serviceAccount:
    automount: false          # required in Agent mode
  vault:
    # The app connects to this Unix socket; the Agent listens on it.
    url: unix:///var/run/permesi/vault-agent/agent.sock
    agent:
      enabled: true
      address: https://vault.example.com:8200   # Vault origin, not the socket
      image:
        repository: hashicorp/vault
        tag: 1.20.4   # pinned
        pullPolicy: IfNotPresent
      auth:
        mount: kubernetes
        role: permesi
        audience: vault
        tokenExpirationSeconds: 3600
      ca:
        existingConfigMap: vault-ca          # public Vault CA; omit for public-root Vault
        key: ca.crt
      pki:
        mount: pki-int
        role: permesi-runtime
        commonName: permesi.permesi.svc.cluster.local
        dnsNames: [permesi.permesi.svc.cluster.local, api.permesi.example.com]
        ttl: 24h
        renewalThreshold: 0.8
      paserkCa:
        enabled: true
        path: pki-int/cert/ca_chain
```

Genesis is identical except it has no `paserkCa` block. See the chart READMEs for
the full table.

### 4.2 What the chart renders (and what it refuses)

- `tls.pemBundlePath` (`/var/run/permesi/tls/bundle.pem` by default) receives one
  atomically-replaced file: exactly one private key, the leaf, then the issuer
  chain. Directory mounts, never `subPath`. File mode `0600` (private key bundle),
  `0644` for the public PASERK CA, socket `0600`.
  The issuer chain is the complete ordered `.Data.CAChain` supplied by Vault,
  including any returned root. Configure Vault with the full chain (§3.6).
- Permesi's PASERK CA is rendered at `admission.paserkCaPath` (or the derived
  `paserkCa.mountPath`/`fileName` default `/var/run/permesi/admission-ca/ca.pem`).
- The socket, TLS bundle, and PASERK CA live in memory-backed `emptyDir` volumes —
  Agent RW, backend RO. `fsGroup` supplies the writable root; the Agent runs as the
  application's existing UID/GID (10001), nonroot, read-only root filesystem,
  `drop: ALL` capabilities, RuntimeDefault seccomp. No `hostPath`, no privileged
  chmod init, no world-writable socket.
- The projected audience-scoped JWT is mounted **only into the Agent**, not the
  backend. `use_auto_auth_token = true` — **never `"force"`** — so an explicitly
  supplied operator token is still forwarded.
- `config.socketPath` (an unrelated application-listener setting) omits the inbound
  PKI template/volume but keeps the Vault socket and Permesi PASERK CA.
- Active socket/TLS/CA destinations must be absolute files inside dedicated
  directories, never `/agent.sock`, `/bundle.pem`, or `/ca.pem`. Normalized
  mount directories must not overlap each other or the Agent's `/vault/config`,
  `/var/run/secrets/vault-token`, `/tmp`, and optional `/vault/ca` mounts.
  `extraVolumeMounts` obey the same ancestor/descendant rule; mounting `/` is
  rejected. Inactive TLS/CA paths do not reserve directories, but legacy Secret
  mounts still count.

### 4.3 Startup gate

A startup probe on the native sidecar blocks initial backend startup until a
tokenless `vault token lookup` through `-address=unix://...` succeeds and required
bundle/CA files are nonempty. File/socket existence alone is insufficient.
`pkiCert` may reuse a valid cached certificate after Agent restart; the probe does
not prove fresh issuance, current certificate validity, or application recovery.
The initial startup gate is not a promise to pause an already-running backend
during an independent sidecar restart.

### 4.4 Production HTTPS

- **Vault**: `vault.agent.address` must be `https://`, with `vault.agent.ca` carrying
  the public Vault CA. The Agent never sets `tls_skip_verify`; its Unix listener
  disables TLS only on the local socket.
- **PostgreSQL**: DSN uses `sslmode=verify-full` plus a CA mounted via
  `extraVolumes`/`extraVolumeMounts`.
- **Private keys never synchronized to Kubernetes Secrets**: the backend gets no
  TLS Secret, no AppRole/DB Secret, and no Vault root token. Public trust anchors
  (Vault CA, PKI CA) may be ConfigMaps.

---

## 5. Service DNS, PASERK trust, frontend, client, email

### 5.1 Service DNS and PASERK trust

- Genesis Service is `<release>-genesis.<namespace>.svc.cluster.local:8080`
  (e.g. `permesi-genesis.permesi.svc.cluster.local`). Permesi's admission keyset URL
  must match, and the Genesis PKI SAN must cover that DNS name.
- `permesi.admission.issuer`/`audience` must equal
  `GENESIS_ADMISSION_ISS`/`GENESIS_ADMISSION_AUD` on the Genesis side, or every
  admission token fails verification.
- Permesi fetches the public PASERK keyset over HTTPS from `/paserk.json`. The
  separate PASERK CA rendered by the Agent is the outbound trust for that endpoint;
  it is **not** the inbound TLS bundle.

### 5.2 Frontend URLs, CORS, OPAQUE ID

`web.runtimeConfig` are browser-side values, not cluster DNS:

```yaml
web:
  runtimeConfig:
    apiBaseUrl: https://api.permesi.example.com
    tokenBaseUrl: https://genesis.permesi.example.com
    clientId: 00000000-0000-0000-0000-000000000000
    opaqueServerId: api.permesi.example.com
```

- `apiBaseUrl`/`tokenBaseUrl` must be reachable from the user's machine.
- `opaqueServerId` must match `permesi.auth.opaqueServerId`.
- `permesi.auth.frontendBaseUrl` and `corsAllowedOrigins` must match the console
  origin.

### 5.3 Provisioned Genesis client and email mode

- Provision a Genesis client; the seed client
  `00000000-0000-0000-0000-000000000000` is a **test-only** fixture, never
  production onboarding.
- Email: `PERMESI_EMAIL_DELIVERY=smtp` (via `extraEnv`) delivers through a relay;
  the default `outbox` mode only queues rows. Production needs a real SMTP relay and
  `PERMESI_AUTH_TRUSTED_PROXIES` scoped to your ingress peers (never `0.0.0.0/0`).

---

## 6. Install, trusted HTTPS checks, admission smoke, edge

### 6.1 Install

```bash
helm dependency build charts/permesi-stack
helm upgrade --install permesi charts/permesi-stack \
  --namespace permesi --create-namespace \
  -f docs/examples/vault-agent-stack.yaml
```

### 6.2 Trusted HTTPS checks (never `-k`)

```bash
export CA=/path/to/your-public-pki-ca.crt

curl --cacert "$CA" --resolve api.permesi.example.com:443:<lb-ip> \
  https://api.permesi.example.com/live
curl --cacert "$CA" --resolve genesis.permesi.example.com:443:<lb-ip> \
  https://genesis.permesi.example.com/paserk.json
curl --cacert "$CA" --resolve genesis.permesi.example.com:443:<lb-ip> \
  "https://genesis.permesi.example.com/token?client_id=00000000-0000-0000-0000-000000000000"
```

A wrong CA or wrong hostname must fail; Kubernetes HTTPS probes do **not** verify
certificates and are not this proof. Import the public PKI CA into the browser
trust store for the console (export only the public CA, never a private key).

### 6.3 Admission/signup smoke

Prove admission: a provisioned client obtains a real Genesis token, and Permesi
accepts it as `X-Permesi-Zero-Token` on an OPAQUE signup start
(`POST /v1/auth/opaque/signup/start` with the correct `Origin`, an allowed email,
and the correct issuer/audience profile). A missing/tampered token or a
wrong-issuer/audience profile must be rejected. The dev seed client UUID is test
configuration only.

### 6.4 Optional Vault-backed edge (no TLS Secrets)

Production with no TLS Secrets prefers TLS passthrough to the backend, or an
operator-provisioned edge that obtains its own TLS files from Vault. The existing
ingress-nginx termination example uses Kubernetes TLS Secrets and is
**legacy/alternative**, not the recommended Agent path. Web's nginx listener is
HTTP-only: an external Vault-backed TLS edge is still required for public HTTPS web
hosting. The Agent does **not** supply ingress/web certificates or database-server
TLS.

---

## 7. Day-2: rotation, recovery, schema upgrades, rollback limits

### 7.1 Leaf certificate reissue/reload vs CA rollout

- **Leaf reissue**: the Agent reissues the TLS bundle before TTL expiry
  (`renewalThreshold` default `0.8`); the app watches the bundle mtime every ~10 s
  and reloads without a pod restart. Do not switch the bundle to `subPath`.
- **CA/intermediate rotation** requires a Permesi **rollout**: the PASERK roots are
  startup-loaded, so roll with overlapping trusted roots before an issuer change,
  then restart pods.

### 7.2 Agent restart and JWT rotation

- The Agent re-reads rotated service-account JWTs. Its probe checks authenticated
  proxy access and required file presence, not new certificate issuance; a valid
  cached bundle can be reused. Verify socket recovery and backend requests after
  an independent Agent restart. End-to-end restart/JWT-rotation evidence remains
  pending M-QS.
- A stopped Agent whose auth token and runtime certificates expire cannot re-issue
  until restarted with valid bootstrap credentials (in the managed chart, this is
  the projected JWT + Kubernetes auth — no cert-auth bootstrap).

### 7.3 DB lease fail-closed recovery

DB lease renewal is owned by the application; renewal failure shuts the pod down
fail-closed so a replacement pod re-acquires fresh credentials. If a DB lease
expires or its parent token is revoked, restart/re-login may still be required —
the Agent does not repair an existing pool automatically. See
`docs/operations.md` for recovery steps.

### 7.4 Schema upgrades and backup/rollback

- Schema changes are explicit operator-run SQL (owner-authenticated, `ON_ERROR_STOP=1`),
  not migrations. Back up PostgreSQL before every schema change.
- Helm rollback does not roll back schema or data; restoring a database whose
  OPAQUE seed/pepper changed is **not** recoverable by generating a fresh seed.
- Back up the KV seed/pepper and the PKI root/intermediate keys separately from the
  database.

---

## 8. Digests, verification, diagnostics, teardown

### 8.1 Image digest and signature verification

Charts pin `image.repository:tag`; when `image.digest` is set (`sha256:<64 hex>`),
the rendered image reference is `repository@digest` and a tag change does not
override it. Clear the digest to return to tag references. App releases sign OCI
images keyless (Cosign) and publish digests; verify against the expected GitHub
OIDC issuer/workflow identity before promoting.

<!-- UNVERIFIED: digest values/helper are M-DIG work; finalize after M-DIG handoff. -->

### 8.2 Restricted diagnostics

Never print or commit secrets, tokens, JWTs, private keys, or PEM key contents.
Sanitize diagnostics: describe status codes, certificate subject/serial, and
rollout state, not credentials. Use `kubectl describe`/`events` with redaction.

### 8.3 Scoped teardown

Production teardown is operator-owned and out of scope for the charts. For the
disposable quickstart, teardown removes only resources the quickstart created; see
the script help (`scripts/quickstart/install.sh`). Never delete a cluster or
namespace you did not create.

### 8.4 Dev state-loss warning

The disposable quickstart runs dev-mode Vault **in memory**: Vault loss with a
retained PostgreSQL loses cryptographic identity (OPAQUE seed, transit keys, PKI),
not merely configuration. A fresh bootstrap cannot manufacture replacement keys
and call the old database recovered. This profile is explicitly not
production-safe.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Chart render fails in Agent mode on an old cluster | `vault.agent.enabled=true` needs Kubernetes ≥ 1.29 with `SidecarContainers`; disable Agent or upgrade the cluster |
| Pod stuck `PodInitializing`, Agent startup probe failing | Vault unreachable, wrong `vault.agent.address`/CA, Kubernetes role/SA/namespace/audience mismatch, or PKI role denies the CN/SAN; check Agent logs (no secrets) and `vault token lookup` from the Agent |
| Backend crash-loops with DB auth failure | DSN placeholder username/password or DB role misconfigured; check `/v1/database/creds/{permesi,genesis}` issuance from Vault |
| Admission tokens rejected | `admission.issuer`/`audience` vs `GENESIS_ADMISSION_ISS`/`AUD` mismatch, or PASERK CA stale after CA rotation |
| Leaf cert not reloading | Bundle mounted via `subPath` (pins old file); use directory mount |
| `check.sql` fails | pg_cron not installed or scheduled jobs not registered |
| AppRole login 404 (Permesi 0.4.3) | `vault.url` must be the full `/v1/auth/approle/login` endpoint, not the base URL |
