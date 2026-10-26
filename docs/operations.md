# Permesi operations runbook

Concise operational runbook for the `permesi-stack` umbrella chart. The
production example (`docs/examples/production-stack.yaml`) demonstrates a
working release/namespace/Service/TLS profile; this document explains the
prerequisites and day-2 procedures behind it.

Component charts: `charts/permesi`, `charts/genesis`, `charts/web`. Application
source paths below are relative to the application repository (`permesi/`).

## 1. Prerequisites

1. **External PostgreSQL with backups.** Both services require externally
   provisioned databases. There is no bundled database and no PVC. Back up your
   database independently; Helm rollback does **not** roll back schema or data.
2. **Schema applied by the owner before rollout.** Schema ownership belongs to a
   dedicated owner role, not the runtime role. Apply `00_init.sql`,
   `01_genesis.sql`, and `02_permesi.sql` (and reapply the additive OAuth/refresh
   scripts on upgrades) as the schema owner *before* the new pods start. See
   `permesi/db/sql/README.md` for ordering, ownership, and verification
   (`check.sql`). The application runs **no migrations**.
3. **Vault** with the `genesis-signing` transit key, AppRole auth, the
   `secret/permesi` KV path, and the `database/creds/{permesi,genesis}` dynamic
   roles. See §2.
4. **TLS material** as Secrets: combined PEM bundles for the backends, a separate
   PASERK CA, and a PostgreSQL CA. See §4.

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

Permesi **≥ the next release** (app branch `feat/k8s-hardening`, unreleased)
accepts a Vault base URL (`https://vault.example.com:8200`, empty or `/` path) and
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
  backend. Verify socket access and application requests after restart; full
  restart/JWT-rotation qualification remains pending M-QS. The native sidecar
  outlives the app container during graceful shutdown.
- **JWT rotation.** The Agent re-reads the projected service-account JWT, so
  service-account token rotation (audience `vault`) is absorbed without pod
  changes. The Kubernetes auth role's `bound_service_account_names`/`namespaces`
  must match the rendered SA name and exact namespace; a mismatched audience/role
  denies login.
- **DB lease fail-closed recovery.** DB lease renewal is owned by the application,
  not the Agent (the Agent has no cache block, so it does not hold a competing
  lease owner). Renewal failure shuts the pod down fail-closed; a replacement pod
  re-acquires fresh credentials via the Agent's socket. If a lease expires or its
  parent token is revoked, restart the pod — do not assume the Agent repairs an
  existing pool automatically.
- **No exposed TCP proxy / no cache / no quit endpoint.** The socket proxy is the
  only listener; it preserves an explicitly supplied operator `X-Vault-Token`
  (never `use_auto_auth_token = "force"`), and Unix requests do not set
  `X-Vault-Request`, so `require_request_header` must stay off.
- **Issuer chains.** The TLS template writes one private key, the leaf, then
  the ordered, deduplicated `.Data.CAChain` returned by Vault, including a root if
  returned. Import the complete chain into the issuing mount; a partial import
  yields a partial served chain. The PASERK CA is a separate JSON-endpoint
  template, not a substitute for the listener's issuer chain.



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

## 10. Chart-only release procedure

A chart-only release (no application release) bumps chart versions while keeping
`appVersion` and image tags unchanged:

1. Bump `version` in `charts/permesi/Chart.yaml`, `charts/genesis/Chart.yaml`,
   `charts/web/Chart.yaml`, and `charts/permesi-stack/Chart.yaml`.
2. Bump the matching dependency `version` entries in
   `charts/permesi-stack/Chart.yaml`.
3. Leave `appVersion` and every `image.tag` (including the
   `# managed-by-release-bot` tags in `charts/permesi-stack/values.yaml`) at the
   current application version.
4. Update the chart install `--version X.Y.Z` references in `README.md` (and any
   chart README using the same pattern) to the new chart version.

Do **not** use `scripts/bump-release.sh` for chart-only releases: it couples
chart, appVersion, and image tag bumps for application releases, and also
rewrites the README install `--version` references alongside them.
