# Permesi operations runbook

Concise operational runbook for the `permesi-stack` umbrella chart. The
production example (`docs/examples/production-stack.yaml`) demonstrates a
working release/namespace/Service/TLS profile; this document explains the
prerequisites and day-2 procedures behind it.

Component charts: `charts/permesi`, `charts/genesis`, `charts/web`. Application
source paths below are relative to the application repository (`permesi/`).

## 1. Prerequisites

1. **Production external PostgreSQL with backups.** Production charts do not
   provision database storage. The opt-in quickstart is disposable, not a
   production database. Helm rollback does **not** roll back schema or data.
2. **Apply canonical SQL before rollout.** Precreate non-superuser schema owners
   with strong static passwords, then run `00_init.sql` against `postgres` with
   `ON_ERROR_STOP=1` and authenticated owner credentials. It includes both service
   schemas and verification; do not separately apply all files as administrator.
   Reapply additive schema changes as the existing owner before upgrading the
   binary. See `permesi/db/sql/README.md`; no application migrations run.
3. **Vault** with the service-specific transit/KV/database/PKI mounts and exact
   SA/namespace/audience Kubernetes bindings for Agent or optional native login.
   AppRole is a supported legacy alternative, not a prerequisite for Agent.
4. **Trust and TLS.** Agent renders backend bundles and Permesi PASERK CA into
   memory volumes, not Kubernetes Secrets. Vault/DB public trust anchors and
   operator-managed edge TLS are separate. Legacy Secret/ESO inputs remain
   supported. See §3 and the [manual guide](install-guide.md).

## 2. Vault setup

### 2.1 AppRole URL semantics (F-01)

Permesi 0.4.3 does **not** normalize `vault.url`: it POSTs the role/secret ID to
that value verbatim (`crates/vault_client/src/lib.rs:121-165`). Use the full login
endpoint for Permesi:

```yaml
permesi:
  vault:
    url: https://vault.example.com:8200/v1/auth/approle/login
```

The **unreleased build** on app branch `feat/k8s-hardening` accepts a Vault base
URL (`https://vault.example.com:8200`, empty or `/` path) and
normalizes it to `/v1/auth/approle/login`; an explicit non-root login URL is still
preserved verbatim. This does not change Agent (socket) mode. Until that release
ships, keep the full endpoint for Permesi.

Genesis normalizes a base URL (or accepts the full endpoint) via
`services/genesis/src/vault/mod.rs:21-26`, so either form works:

```yaml
genesis:
  vault:
    url: https://vault.example.com:8200
```

### 2.2 Restart-safe authentication (F-02)

The application logs in on every startup and cannot reuse a consumed one-use
credential. The supplied Terraform AppRole defaults
(`vault/contrib/terraform/approle.tf:11-14`) set `secret_id_num_uses = 1` and a
one-hour SecretID TTL (`secret_id_ttl = 3600`); tokens themselves expire at
`token_ttl = 3600` with `token_max_ttl = 14400`. Renewal failure shuts the pod
down so it can re-login (`crates/service_utils/src/vault/renew.rs:118-122`).

Credentials must therefore remain valid for **every future pod start**, not just
the current rollout: restarts, rescheduling, scale-out, and the re-login that
follows a token `max_ttl` expiry or renewal failure. Pick **one** of:

- **Vault Agent (recommended).** Use the chart-managed Agent sidecar
  (`vault.agent.enabled: true`). It authenticates via Kubernetes auth and renders
  the TLS bundle and (for Permesi) the PASERK CA; set `vault.url` to the Unix
  socket it listens on. The agent re-authenticates and renews independently of the
  application, so replicas and restarts always have a live token. The agent socket
  must already exist when the transport is constructed. See §2.4.
- **Long-lived SecretID plus a rotation procedure.** Provision the AppRole with a
  `secret_id_num_uses`/`secret_id_ttl` policy that covers the Secret's whole
  service life, and rotate it *before* expiry: update the Secret, then
  `kubectl rollout restart` the Deployment so every replica re-logs-in with the
  new SecretID. A SecretID whose TTL merely outlives the current rollout is not
  enough — a later restart, scale-out, or re-login after a renewal failure would
  hit an expired or exhausted credential.

**Per-replica one-use credentials do not survive restarts.** With
`secret_id_num_uses = 1`, each SecretID can be consumed once, so replicas beyond
the first (and any later restart) fail; distributing a distinct one-use SecretID
per replica still breaks on rescheduling or restart.

**Wrapped tokens are bootstrap-only.** A response-wrapping token can be consumed
exactly once, even if the underlying SecretID allows multiple logins. Use wrapped
tokens only for a single initial bootstrap, never as steady-state HA credentials.

### 2.3 Dynamic database credentials

The application always replaces DSN credentials with Vault-issued ones from fixed
paths `/v1/database/creds/permesi` and `/v1/database/creds/genesis`
(`services/permesi/src/cli/actions/server.rs:118-131`). Renewal failure triggers a
deliberate restart so the pod re-acquires fresh credentials. The DSN Secret can
therefore carry a placeholder username/password; only host/port/database and TLS
options matter.

### 2.4 Managed Vault Agent operations

The recommended path is the chart-managed Agent sidecar (`vault.agent.enabled:
true`): a native sidecar (`initContainers[].restartPolicy: Always`) running the
official `hashicorp/vault` image with Kubernetes auto-auth, a local Unix-socket
proxy (`api_proxy { use_auto_auth_token = true }`, **no cache block**), and PKI
templates rendering the TLS bundle and (Permesi only) the PASERK CA. Kubernetes
≥ 1.29 with `SidecarContainers` is required in this mode. See
`docs/install-guide.md` §4 and `docs/examples/vault-agent-stack.yaml`.

- **Leaf reissue/reload vs CA rollout.** The Agent reissues the TLS bundle before
  TTL expiry (renewal threshold default `0.8`, leave margin for retries plus the
  backend's ~10 s reload). The application watches the bundle mtime and reloads
  in place; do **not** switch the bundle to a `subPath` mount. A certificate is
  reissued, not renewed in place. CA/intermediate rotation is different: the
  PASERK roots are startup-loaded, so roll with overlapping trusted roots before
  an issuer change, then `kubectl rollout restart` the backends.
- **Agent restart.** The startup probe checks authenticated proxy access and
  nonempty required files before initial backend startup; existence alone is not
  sufficient. `pkiCert` may reuse a valid cached bundle after restart, so a probe
  success does not prove fresh certificate issuance. An independent sidecar
  restart does not re-run the initial startup gate for the already-running
  backend. Verify socket access and application requests after restart. The M-QS
  local driver reports Agent-only restart recovery; natural projected-JWT
  expiry/rotation is not qualified by that scenario. The native sidecar
  outlives the app container during graceful shutdown.
- **JWT rotation.** The Agent re-reads the projected service-account JWT, so
  service-account token rotation (audience `vault`) is absorbed without pod
  changes. The Kubernetes auth role's `bound_service_account_names`/`namespaces`
  must match the rendered SA name and exact namespace; a mismatched audience/role
  denies login.
- **DB lease fail-closed recovery.** The application, not Agent, owns DB lease
  renewal. The corrected verifier synchronously revoked each service's real pool
  leases, observed exact old roles disappear, a nonzero application exit and
  same-pod restart with new pool identities, then trusted HTTPS/admission
  recovery. Restore Vault/DB connectivity and allow the Deployment to restart
  the app; do not assume Agent repairs a live pool. This DB-lease proof does not
  qualify revocation of the Agent workload auth token itself.
- **No exposed TCP proxy / no cache / no quit endpoint.** The socket proxy is the
  only listener; it preserves an explicitly supplied operator `X-Vault-Token`
  (never `use_auto_auth_token = "force"`), and Unix requests do not set
  `X-Vault-Request`, so `require_request_header` must stay off.
- **Issuer chains.** The TLS template writes one private key, the leaf, then
  the ordered, deduplicated `.Data.CAChain` returned by Vault, including a root if
  returned. Import the complete chain into the issuing mount; a partial import
  yields a partial served chain. The PASERK CA is a separate JSON-endpoint
  template, not a substitute for the listener's issuer chain.

### 2.5 Optional native Kubernetes login

Requires an **unreleased rebuilt application image**; default `0.4.3` does not
support native-auth flags. `vault.authMethod=auto` preserves socket→Agent and
TCP→AppRole; `approle` explicitly selects TCP AppRole; `kubernetes` selects direct
application login using `vault.kubernetes.*` and requires Agent disabled plus
`serviceAccount.automount=false`. See the component READMEs for exact defaults.
Native mode projects its audience-scoped JWT only into the app, grants no RBAC,
and does not render TLS/PKI/PASERK files. Vault's reviewer, never the app SA,
needs TokenReview.

Remove known AppRole/wrapped-token/ESO credential inputs before cutover. Generic
`extraEnvFrom` imports remain supported and opaque to Helm; operators must remove
legacy AppRole credential variables from their contents. The application rejects
native-mode credential conflicts rather than falling back.

Reauthentication is restart-based, not a shared hot-swapped token session.
After token/DB renewal failure the process drains/stops. Once Vault/reviewer/DB
dependencies are healthy, let the Deployment restart the process or explicitly
roll the affected Deployment; it reads the latest projected JWT and reacquires
credentials. Do not assume replacing a JWT repairs an already-issued token or DB
pool. Standalone native login/renewal was exercised in the application milestone;
full native-auth supervisor/DB recovery is not claimed by the Agent quickstart.



## 3. TLS

- **Inbound backend TLS** is one combined PEM bundle — private key followed by
  certificate chain — mounted at `tls.pemBundlePath`. In the legacy path it comes
  from a Secret; in Agent mode the Agent renders it from the PKI role into the
  same path. No client certificate authentication is performed
  (`crates/service_utils/src/tls.rs:239-265`).
- **Certificate reload** watches the bundle's modification time every 10 seconds.
  Mount the Secret as a directory (the chart default) so projected updates are
  observed; do **not** switch to `subPath` mounts, which pin the old file.
- **Outbound PASERK trust is separate.** Permesi trusts the Genesis admission
  endpoint via system roots plus `admission.paserkCa`; the server's own TLS bundle
  is *not* automatically the outbound trust store. Supply a dedicated CA Secret at
  `permesi.admission.paserkCa.existingSecret` when Genesis uses a private CA.
- **Vault trust** uses the image's root bundle (`SSL_CERT_FILE`, default
  `/etc/ssl/certs/ca-certificates.crt`). There is no dedicated Vault CA flag; add
  your private CA to the image trust bundle or use a CA that chains to public
  roots. In Agent mode the application talks to Vault over the Unix socket and the
  **Agent** holds the Vault CA (`vault.agent.ca.existingConfigMap`); the backend
  image needs no Vault CA.
- **PostgreSQL TLS** is controlled by the DSN. Use `sslmode=verify-full` plus
  `sslrootcert=<path>` where `<path>` points at a CA mounted via
  `extraVolumes`/`extraVolumeMounts` (see the example). The development default
  `sslmode=disable` must not be used in production.

## 4. Split trust and admission verification

- Genesis signs admission tokens with the Vault transit Ed25519 key
  `genesis-signing`; private signing material is never distributed
  (`services/genesis/src/api/admission.rs:200-295`).
- Permesi only fetches the **public** PASERK keyset from
  `/paserk.json` and verifies tokens locally
  (`services/permesi/src/api/handlers/mod.rs:133-171`). Genesis publishes the
  latest and previous key versions, with ~300 s cache and 30 s throttled refresh.
- The issuer and audience must match on **both** sides:
  `permesi.admission.issuer`/`audience` (verifier) must equal
  `GENESIS_ADMISSION_ISS`/`GENESIS_ADMISSION_AUD` (signer). A mismatch fails
  verification for every token.
- Do not confuse Permesi's `/jwks.json` and
  `/.well-known/openid-configuration` (its OIDC authority, signed by the separate
  `oidc-signing` key) with Genesis admission verification.

## 5. Probes and shutdown

- **Liveness** `/live` is dependency-free (both services).
- **Readiness** `/ready` checks PostgreSQL and (for Permesi) admission-keyset
  health — not general Vault health
  (`services/permesi/src/api/handlers/health.rs:49-110`,
  Genesis `health.rs:40-96`). DB authentication failure can drive a fail-closed
  shutdown so a replacement pod fetches fresh Vault credentials.
- **Web** `/healthz` is nginx-only; it does not prove valid runtime config or a
  working API/Genesis.
- **Graceful shutdown budget:** SIGTERM triggers a bounded 30 s request drain,
  then Permesi allows ~10 s for email-worker shutdown and ~5 s for pool close
  (`crates/service_utils/src/shutdown.rs:21-77`,
  `services/permesi/src/api/mod.rs:208-238`). Keep
  `terminationGracePeriodSeconds` at **60 s** (the backends' default) so the pod
  is not SIGKILLed mid-drain; sidecars must also finish within the same budget.

## 6. High availability

- Run `replicaCount: 2` (or more) with a PDB (`minAvailable: 1`) and HPA
  (`minReplicas: 2`). `replicas` is omitted from the Deployment when HPA is
  enabled.
- Budget the database pool across **maximum replicas plus rollout surge**, not
  steady-state. With `db-max-connections` defaulting to 10 per process and a
  `maxReplicas` of 6, a rolling update can briefly run 7+ pods
  (`crates/service_utils/src/database.rs:79-109`). Keep
  `maxReplicas × (db-max-connections + 2)` below the PostgreSQL `max_connections`
  headroom. Tune via `extraEnv` (`PERMESI_DB_MAX_CONNECTIONS`, etc.).
- Topology spread and affinity are exposed but opt-in; the example sets zone/host
  spread constraints.

## 7. NetworkPolicy

Enabling `networkPolicy` sets `policyTypes: [Ingress, Egress]` and renders empty
`ingress`/`egress` lists when no rules are supplied — i.e. **deny-all** semantics.
Turning policy on without allow-lists will cut off all traffic. The example lists
the required flows: DNS, PostgreSQL, Vault, SMTP, Permesi→Genesis 8080, and the
ingress controller namespace. Web pods need only DNS egress (the browser, not
nginx, calls the backends). Adjust namespace labels and `ipBlock` CIDRs to your
environment.

## 8. Rotation and rollout

- **Env secrets require a restart.** The DSN and Vault credentials are injected
  via `secretKeyRef` (environment variables), which are read only when the pod
  starts. Rotate the Secret, then `kubectl rollout restart deployment <fullname>
  -n permesi`.
- **PASERK CA requires a restart.** Permesi reads the admission PASERK CA once at
  startup (`services/permesi/src/api/handlers/mod.rs:139-150`); rotating that CA
  Secret does not take effect until the pod restarts.
- **Inbound TLS bundle auto-reloads.** Only the directory-mounted inbound TLS
  bundle is re-read when its file changes (watched every ~10 s); do **not**
  switch it to a `subPath` mount, which pins the old file.
- **Web runtime config:** the chart-managed ConfigMap is checksummed into the pod
  template, so a runtime-config-only upgrade rolls pods. With
  `existingConfigMap`, Helm cannot hash external data — run
  `kubectl rollout restart deployment <name>` after editing it.
- A generic rollout restart for any pod:
  `kubectl rollout restart deployment <fullname> -n permesi`.

## 9. Upgrade checklist

1. Back up PostgreSQL and Vault state.
2. Apply/reapply schema as the owner (`permesi/db/sql/README.md`).
3. Confirm Vault roles/keys and dynamic-cred paths still exist; rotate SecretIDs
   if they were one-use.
4. Diff rendered manifests:
   `helm template permesi charts/permesi-stack -n permesi -f <values>.yaml > /tmp/manifests.yaml`
5. `helm upgrade --install permesi ... -f <values>.yaml`.
6. Verify readiness and that admission token verification still works
   (issuer/audience unchanged).
7. If the upgrade only changed chart-managed web runtime config, pods roll
   automatically (checksum); otherwise use `kubectl rollout restart`.

## 10. Release and image identity

`image.digest` and backend `vault.agent.image.digest` default to `""`.
Nonempty `sha256:<64 lowercase hex>` wins over `tag` and renders
`repository@digest`; otherwise `repository:tag` is used. Changing a tag while
keeping a digest does not change the deployed image. Update or clear the digest
deliberately. Agent image identity is independent of app-release automation.

### Independent application and chart versions

Run these mutation commands only when preparing an authorized local release
change; they do not push, tag, publish or dispatch:

```bash
# App release, exact digests for all services (set these from trusted metadata).
bash scripts/bump-release.sh --chart-version "$CHART_VERSION" \
  --digest "permesi=$PERMESI_DIGEST" --digest "genesis=$GENESIS_DIGEST" \
  --digest "web=$WEB_DIGEST" "$APP_VERSION"

# Intentional tag-only app release: clears every managed app digest.
bash scripts/bump-release.sh --chart-version "$CHART_VERSION" --tag-only "$APP_VERSION"

# Chart-only release: preserves appVersion and all image values byte-for-byte.
bash scripts/bump-release.sh --chart-only "$CHART_VERSION"
```

The legacy single `<version>` form remains tag-only and also clears old app
digests. Without `--chart-version`, app version becomes chart version only if it
advances every current chart; otherwise the maximum chart version advances one
patch. Explicit chart versions must strictly advance. No version regression is
permitted (current charts may be ahead of appVersion).

App releases update standalone and umbrella tags/digests together. Chart-only
updates change chart/dependency versions, not appVersion or image identities.
Rebuild dependency packages after component/version changes:

```bash
helm dependency update charts/permesi-stack
helm dependency build charts/permesi-stack
```

`update` refreshes a stale ignored Chart.lock after version changes; `build` alone
does not repair a lock that references old dependency versions.

### Release event boundary

`.github/workflows/release-bump-pr.yml` invokes
`scripts/ci/release-event.sh`, which parses `GITHUB_EVENT_PATH` with jq, never
interpolating payload fields as executable shell. Repository dispatch requires:

- `client_payload.version` (`X.Y.Z` or `vX.Y.Z`);
- `source_repo: permesi/permesi`, a 40-lowercase-hex `source_sha`, matching
  `source_tag`;
- `images.{permesi,genesis,web}.{repository,tag,digest}`, expected
  `ghcr.io/permesi/<service>` repositories and normalized version tags;
- either three valid digests, or all three explicit empty digest strings plus
  **JSON boolean** `client_payload.tag_only: true`. Missing fields, partial sets,
  string `"true"`, null and other nonboolean acknowledgement values fail closed.
  Omitted acknowledgement defaults false. `tag_only=true` with digests is rejected.

Manual workflow dispatch exposes `version`, optional `chart_version`, the three
`<service>_digest` inputs and an explicit `tag_only` acknowledgement. Workflow
input normalization is separate from the repository-dispatch JSON boolean rule.
The application sender explicitly acknowledges tag-only mode; all-empty inputs
never infer consent. PR metadata records app/chart versions, source identity and
digest/tag-only mode.

Local regression command (Git, Bash, jq, Python 3 and PyYAML required):

```bash
python3 scripts/ci/test-release.py
```

It invokes the actual parser and bump script in unique disposable worktrees;
synthetic digest fixtures prove validation/render contracts, not registry
existence or signatures. `hc` may not have jq: run the release suite where its
dependencies exist. No GitHub dispatch/publish/signing execution is implied.
`Charts CI` also runs this command in its independent `release-contracts` job
(13 tests; Python 3.12 and PyYAML 6.0.3). This local suite is distinct from
the real-dependencies cluster driver and from remote release execution.

## 11. Quickstart qualification and known boundaries

Bootstrap correction `de750e5` separates static canonical schema owners
`vault_permesi`/`vault_genesis` from non-owner credential managers
`vault_permesi_manager`/`vault_genesis_manager`. Managers get only their matching
runtime role's ADMIN option with INHERIT/SET disabled, own-DB CONNECT,
CREATEROLE and pg_signal_backend. Vault rotates the manager password immediately
after first configuration and never resets it on rerun. Schema-owner passwords
remain stable for authenticated schema bootstrap and maintenance.

The bootstrap correction report runtime-qualified both manager rotations plus
rerun/data/identity preservation, colon/backslash passwords and CR/LF rejection,
filtered root/unseal banner output with correct signal/exit handling, hashed
namespace-safe reviewer RBAC names, and a real limited-privilege pregranted
installation. Older owner-as-manager dev configs fail explicitly: use a
manager-separated restore or reset only the disposable namespace. Do not reset
the schema-owner password or automatically migrate an unknown legacy config.

Verifier correction `a81d64b` privately tracks each exact issued role/lease,
checks its privileges, propagates synchronous revocation errors and verifies
that role disappears. Fault-injected missing membership and broken revocation
both failed verification. Runtime forwards parse their own child process's
dynamic loopback announcement; simultaneous verifiers with different CAs passed
while the old fixed ports were occupied. These verifier ports are separate from
the fixed user-facing browser ports in `connect.sh`.

The correction report's complete driver passed in 296.19s, including both
services' actual pool-lease fail-closed restart/new-credential/admission recovery,
leaf reload, Agent restart, replacement/scaling and reinstall preservation.
Its complete umbrella wrapper also passed with explicit
`--helper-release permesi --helper-fullname permesi-quickstart`. These are
attributed report results, not a fresh driver run by the documentation builder.

Natural projected-JWT expiry/rotation, exact Agent workload-token revocation,
outbound PASERK wrong-CA/SAN negatives, CA-root rotation, production durability/
HA/TLS, NetworkPolicy enforcement, SMTP, browser/WASM signup and verified-email/
login/OIDC E2E remain separate qualifications. GitHub-hosted execution is not
implied. The disposable quickstart still has no pg_cron scheduler; production
scheduler execution and external reviewer provisioning are separate manual-guide
procedures, not claims derived from the dev driver.

### CI driver and external qualifications

The corrected full CI driver defaults to the disposable namespace **`qv-ci`**.
Its fault-injection harness requires `qv-*`; the driver rejects other namespace
prefixes before installing resources. This restriction applies to the CI driver,
not ordinary `install.sh`. Use an isolated context and a matching locked app SQL
checkout; the admission helper must be compatible with the tooling environment:

```bash
QS_CONTEXT=kind-permesi-helm-test QS_NAMESPACE=qv-ci \
  QS_APP_SOURCE=/path/to/locked/permesi QS_CHARTS_DIR=charts \
  QS_ADMISSION_BIN=/path/to/compatible/quickstart-admission \
  bash scripts/ci/real-dependencies.sh
```

Lead's final evidence at implementation `9742558` reports this default-path run
passed in **302.47s**, including independent missing-GRANT/broken-revocation
faults, both services' actual pool-lease recovery and reinstall preservation.
It separately reports the integrated Helm-only profile and complete explicitly
mapped wrapper passed. These supersede earlier preflight-failed/pre-correction
driver attempts; they do not prove natural JWT/token-max-TTL expiry or production
operation.

The documentation qualification separately exercised
[external Vault reviewer replacement](install-guide.md#external-vault-dedicated-reviewer-and-explicit-configuration)
and [pg_cron background-worker execution](install-guide.md#23-production-scheduler-pg_cron-and-verification).
External Vault ran outside Kind: both application logins succeeded before/after a
distinct reviewer replacement, wrong SA/audience/cross-role requests failed,
apps lacked TokenReview, and scoped management identities were enforced. JWT
expiry, periodic management-token renewal and the operator-host timer were not
elapsed-time tested.

The PostgreSQL qualification executed both canonical maintenance jobs before and
after changing both non-owner manager passwords; all 12 runs succeeded, including
partition rollover/retention and expired-row cleanup effects. Owner credentials
and job/function ownership remained unchanged. That scheduler experiment changed
passwords via SQL, not Vault's rotate-root API; the bootstrap report supplies its
separate API/rerun proof. Neither experiment certifies production TLS, failover,
capacity or a managed service's permissions.

Initial manager-config creation and first root rotation are distinct steps.
Treat an interruption between them as incomplete provisioning: require successful
authorized manager rotation before enabling workloads. No automatic repair of
that interruption is claimed here.
