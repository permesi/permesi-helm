# Kubernetes adoption plan (D1)

## 1. Decision and scope

Make **chart-managed Vault Agent + Kubernetes authentication + Vault PKI** the recommended opt-in backend profile. Keep the existing Secret/ESO/AppRole interfaces and default manifests unchanged. Do not introduce cert-manager or synchronize application TLS private keys into Kubernetes Secrets.

Deliver the real-dependency Kind gate and script quickstart from one reusable development dependency/bootstrap chart under `scripts/quickstart/`. Then make that chart an optional umbrella dependency. Production continues to use externally operated PostgreSQL and Vault; quickstart is explicitly disposable, not a small production installation.

Application work belongs on a separate feature branch in `permesi/`: implement backward-compatible Permesi Vault URL normalization, fix nginx header inheritance, and sign/attest OCI image digests. **Do not make native application Kubernetes auth a prerequisite:** Agent already supplies it and is still needed for PKI rendering. Section 7 gives the decision and the complete alternative contract rather than silently treating native auth as delivered.

Paths below are workspace-relative unless a section says otherwise. This document supersedes only the relevant exclusions in `permesi-helm/docs/engineering/helm-improvement-plan.md` §6. Its §7–8 remains the record of already completed hardening, not proof of backend integration.

## 2. Verified facts and implications

| Fact | Source | Design implication |
|---|---|---|
| Both trees were clean at inspection; application branch `sandbox`, chart branch `feat/helm-hardening`. | `git -C <repo> status --short --branch` | Preserve branches; writing builders use dedicated feature worktrees. D1 changes only this document. |
| Existing charts have effective ESO names, Restricted seccomp, backend 60-second grace, and web runtime checks. | Chart `templates/{deployment.yaml,_helpers.tpl}`, values; prior plan §7–8 | Extend these helpers; do not replace conventions or repeat completed fixes. |
| Agent target accepts `/absolute/path` or `unix:///absolute/path`; construction immediately stats the path. This is only an existence check, not a successful connection or permission check. | `permesi/crates/vault_client/src/transport.rs:48-84,127-145,400-417` | Socket must exist before backend startup; acceptance must exercise a real authenticated request, not merely `test -S`. |
| Ordinary Agent-mode startup skips AppRole and leaves the service token empty. DSN username/password are replaced by dynamic credentials. | `services/permesi/src/cli/actions/server.rs:86-131`; service Vault argument modules | Set backend `vault.url` to the socket, not Vault's HTTPS address. Do not render DB credentials into environment variables/files. |
| The transport can forward an explicitly supplied `X-Vault-Token` even over the socket. Permesi operator step-up deliberately does this. | `crates/vault_client/src/transport.rs:247-264`; `services/permesi/src/vault/step_up.rs:38-66` | Agent `use_auto_auth_token = true`, **not `"force"`**. Forcing the workload token breaks operator-token lookup semantics. Never give the workload operator privileges. |
| Unix requests do not set `X-Vault-Request`. | `crates/vault_client/src/transport.rs:251-264` | Do not enable Agent `require_request_header` without a separately tested application change. |
| Agent mode skips application token renewal, but the application still renews DB leases. Renewal failure requests fail-closed shutdown. | `crates/service_utils/src/vault/renew.rs:50-73,139-205` | Disable Agent response caching; avoid two independent owners of DB lease renewal. Restart/re-login may still be needed when a DB lease expires or its parent token is revoked. |
| Combined inbound PEM is required, exactly one private key; certificates remain in file order. The watcher checks mtime every 10 seconds. PASERK CA is loaded into a client once. | `crates/service_utils/src/tls.rs:235-350`; `services/permesi/src/api/handlers/mod.rs:133-173` | Atomically replace one key + leaf + issuer-chain file; directory mounts, never `subPath`. CA rotation needs a Permesi rollout, unlike leaf rotation. |
| Backend images are `scratch`, user 65532; charts currently run UID/GID/fsGroup 10001. | `services/{permesi,genesis}/Dockerfile`; backend `values.yaml` | No shell, curl, chmod, or wait wrapper in backend containers. Put preparation/probes in the Agent image. |
| Permesi posts AppRole login to the supplied URL verbatim. Genesis has `approle_login_url`, but its current substring check only recognizes the standard mount. | `services/permesi/src/vault/mod.rs:34-36`; `services/genesis/src/vault/mod.rs:18-26`; `crates/vault_client/src/lib.rs:119-170` | Normalize only origin/root URLs for Permesi. Preserve existing explicit custom login paths; do not copy Genesis's substring heuristic blindly. |
| KV v2 is mounted at `secret/permesi`, logical key `config`, API path `secret/permesi/data/config`. Both secret fields are standard-base64 32 random bytes. | `vault/contrib/terraform/secrets.tf` | Do not mistakenly mount KV at `secret` and write a different key hierarchy. Preserve seed/pepper on reruns. |
| Transit keys are `transit/permesi/keys/totp` (chacha20-poly1305), `transit/genesis/keys/genesis-signing` (Ed25519), optional separate RSA-2048 `oidc-signing`. | `vault/contrib/terraform/transit.tf` | Separate mounts/policies; no Genesis signing capability for Permesi. |
| Vault DB connections and credential roles are separate per database; runtime identities get only membership of their corresponding runtime role. | `vault/contrib/terraform/databases.tf` | Copy creation, renewal, and revocation semantics, not generic broad grants. |
| `00_init.sql` includes ownership checks, both service schemas, Genesis test seed, and Permesi verification. It switches to fresh owner-authenticated connections; it is not just database creation. | `db/sql/00_init.sql:45-122`, `db/sql/README.md:57-73` | Run the canonical include tree once with `ON_ERROR_STOP`; do not independently reapply all three files as administrator or substitute `SET ROLE`. |
| Current verification uses `MAINTAIN`; application CI uses official PostgreSQL 18. `check.sql` additionally requires pg_cron and both registered jobs. | `db/sql/verify_permesi.sql`, `db/sql/check.sql:51-94`, `.github/workflows/test.yml:248-284` | Use PostgreSQL 18 for quickstart. Stock PostgreSQL schema smoke is not a successful `check.sql`/production scheduler check. |
| Genesis `/token?client_id=UUID` signs a 120-second token, using a provisioned client. Permesi accepts it as `X-Permesi-Zero-Token` on OPAQUE signup. | `services/genesis/src/api/handlers/token.rs:23-35,91-117`; `services/permesi/src/api/handlers/auth/{zero_token.rs,opaque/signup.rs}` | Test real signing, HTTPS PASERK fetch, and successful signup start; readiness alone is insufficient. |
| nginx locations set their own `add_header`, losing inherited server headers under ordinary nginx inheritance. | `apps/web/nginx.conf:30-84` | Fix application nginx configuration, not Helm values. |
| App workflow publishes image digests and dispatches `client_payload.images.<service>.{repository,tag,digest}`. Helm receiver ignores the image object. | `.github/actions/dispatch-helm/action.yml:95-106`; Helm `.github/workflows/release-bump-pr.yml:27-57` | Wire the actual nested payload, not hypothetical flat digest properties. |
| App candidate builds push `sha-<commit>` images; release retags exact digests using `skopeo --preserve-digests`. Existing provenance step attests `dist/*` files; frontend signing is a separate workflow call. No OCI digest signing/attestation step appears in the image jobs. | `.github/workflows/deploy.yml:329-343,375-457,540-546,685-752` | Preserve build-once promotion. Add OCI signing at candidate image creation; do not rebuild on release or claim file attestations sign OCI manifests. |

### Evidence actually executed for D1

- Read the requested chart plan, operations guide, production profile, chart interfaces, smoke script, relevant application source, Terraform, SQL, and release workflows.
- `/tmp/permesi-tools/hc kubectl get nodes -o wide`: existing `permesi-helm-test-control-plane` was Ready, Kubernetes **v1.32.2**.
- `/tmp/permesi-tools/hc kubectl get pods -A`: system and local-path-storage pods only; no running application/dependency deployment to validate.
- `/tmp/permesi-tools/hc helm template d1 charts/permesi --namespace d1 --show-only templates/deployment.yaml`: succeeded. Observed two replicas, UID/GID 10001, socket environment variable, and **no provisioned Agent/TLS volumes** under defaults.
- No repository builds/tests, cluster mutations, image publishing, secret reads, or application edits were performed. Proposed runtime acceptance below is **not executed evidence**.

## 3. M-VA: managed Vault Agent design

### Delivery choice

Use a chart-rendered **native sidecar**: `initContainers[].restartPolicy: Always`. Require Kubernetes **>=1.29 with SidecarContainers enabled** when `vault.agent.enabled=true`; recommend >=1.33 where it is stable. Fail rendering on an older Kubernetes version only in this opt-in mode. Kubernetes 1.29–1.32 feature-gate availability still needs server-side validation.

A startup probe on the native sidecar blocks subsequent initialization and backend startup. Native sidecars also outlive the main container during graceful shutdown. A conventional init Agent can render files, but cannot leave a live socket after it exits; a conventional sidecar races the scratch backend. Do not hide that race with CrashLoopBackOff. Injector annotations remain supported through existing escape hatches when managed mode is off; do not install a mutating webhook/CRDs for the recommended self-contained path. Do not run both injectors and managed Agent.

Upstream: [Kubernetes sidecar lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/). This is a deliberate supported-version boundary, not a claim that every historical Kubernetes version works.

### Additive values contract (both component charts)

| New key | Default / contract |
|---|---|
| `vault.agent.enabled` | `false` |
| `vault.agent.address` | Empty; required HTTP(S) Vault origin when enabled; HTTPS in production. Independent of `vault.url`. |
| `vault.agent.image.{repository,tag,digest,pullPolicy}` | Official `hashicorp/vault`, explicit tested patch version, optional digest, `IfNotPresent`. Resolve/test an available supported version; never `latest`. |
| `vault.agent.auth.{mount,role,audience,tokenExpirationSeconds}` | `kubernetes`, required role, `vault`, `3600`; mount omits `auth/`; projected token audience must match Vault role. |
| `vault.agent.ca.{existingConfigMap,key}` | Empty / `ca.crt`; public trust anchor for Vault transport, optional for public-root Vault. No private key. |
| `vault.agent.pki.{mount,role,commonName,dnsNames,ttl}` | `pki-int`, required service-specific role, required CN/SAN configuration, `[]`, `24h`. |
| `vault.agent.pki.renewalThreshold` | `0.8`; strict `0 < x < 1`; allow margin for retries plus backend's 10-second reload. |
| `vault.agent.resources` | Small explicit requests/limits; account for them in pod sizing. |
| `vault.agent.startupProbe.{periodSeconds,timeoutSeconds,failureThreshold}` | Bounded startup budget, initially 5/5/120; expose tuning. |
| `vault.agent.paserkCa.{enabled,path}` | Permesi only: `true`, `pki-int/cert/ca_chain`; authenticated JSON endpoint, not raw PEM endpoint. |

Reuse **existing destinations**: `vault.url` is the absolute/Unix socket path; `tls.pemBundlePath` is the bundle path; Permesi `admission.paserkCaPath`, if nonempty, is the CA destination, otherwise derive existing `paserkCa.mountPath/fileName`. Do not create a second competing path field. Parse `unix://` for volume paths while preserving the application value. Compute mount directories/basenames with existing helpers. Separate socket/TLS/CA volumes; detect conflicting/overlapping mount directories and reserved volume names instead of generating invalid mounts.

Validation when enabled:

- Require a Unix target, Agent address/role, and TLS PKI role/SANs in TCP-serving mode. `config.socketPath` remains the unrelated **application listener** setting: if set, omit inbound PKI template/volume, retain Vault socket and Permesi PASERK CA.
- Reject AppRole credentials/wrapped tokens and Vault ESO credential sources; reject TLS Secret/ESO and PASERK Secret/ESO sources only when Agent manages the corresponding artifact. Keep DSN Secret/ESO valid.
- Reject injector activation, duplicate chart-owned env entries for these destinations, and collisions with reserved mounts. Validate absolute writable destination paths and distinct socket/file destinations.
- Require explicit nonroot application UID/GID and compatible fsGroup for managed mode. Agent runs as the same UID/GID, derived from existing security context, not a second hard-coded identity. Preserve current 10001 defaults.
- Require `serviceAccount.automount=false` in managed mode; existing off-mode defaults remain unchanged. Explicit projected JWT is mounted **only into Agent**, not the backend. Existing ServiceAccounts are supported; they need no Secret read/list or TokenReview permission.

### Pod and Agent configuration

Add `templates/configmap-vault-agent.yaml` and a chart-prefixed helper file for Agent configuration/pod fragments. Checksum the non-secret configuration into pod annotations while preserving user annotations. Avoid a shared chart library for two small instances.

- Memory-backed `emptyDir` for socket, TLS bundle and PASERK CA; Agent RW, backend RO directory mounts. Socket connect permission is still required despite RO mount. `fsGroup` supplies writable volume roots; Agent creates nested private directories as needed. File mode `0600` for private-key bundle, `0644` for public CA, socket `0600` with same UID (or deliberately verified equivalent group restriction). No world-writable socket, privileged chmod init, or hostPath.
- Agent private writable scratch volume for PID/HOME/temp; root filesystem read-only, nonroot, drop ALL capabilities, no privilege escalation, RuntimeDefault seccomp. Bypass any image entrypoint requiring root/chown/setcap; run the verified Vault binary directly. Shell probes run in the Agent image only.
- `auto_auth.method "kubernetes"`: `mount_path="auth/<mount>"`, role and `token_path` pointing to the projected JWT. No token sink exposed to the backend. Agent re-reads rotated service-account JWTs.
- Unix listener with TLS disabled **on the local socket only**. `api_proxy { use_auto_auth_token = true }`. **No `cache` block**, no exposed TCP proxy Service, no quit endpoint. Preserve explicit operator token headers.
- Vault stanza uses `address` and CA file with certificate verification; no `tls_skip_verify`. Agent address must not point back to its own listener.
- PKI template uses one `pkiCert` request for the bundle: `.Data.Key`, `.Data.Cert`, `.Data.CA`, with leaf first among certificates. Configure exact role SANs, `ttl`, `error_on_missing_key=true`, `backup=false`, permissions, and `template_config.lease_renewal_threshold=0.8`. Verify full intermediate chain in the selected issuer configuration. A certificate is **reissued**, not renewed in place.
- Permesi CA template uses `secret "pki-int/cert/ca_chain"` and `.Data.certificate`; template `secret` expects JSON. Do not use `pki-int/ca` (raw PEM) or assume Terraform's existing `pki-int/ca_chain` policy covers `/cert/ca_chain`.
- Native sidecar startup probe must establish: socket is a live authenticated proxy, required bundle and CA have completed rendering. Use a tokenless `vault token lookup` through `-address=unix://...`, suppressing its output, plus file tests in the Agent image. Verify that selected Vault CLI supports the Unix address. No read of `database/creds` on every probe, no credential/token output. Template failures must fail the gate, not produce `<no value>`.
- Readiness may use the same lightweight proxy check; do not add dependency-driven liveness. Test Agent restart with old files still present: a stale socket/file existence check must not release startup before fresh auth.

HashiCorp references: [Agent templates and `pkiCert`](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template), [Kubernetes auto-auth](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/kubernetes), [API proxy header precedence](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/apiproxy), [cache renewal ownership](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/caching). Unix listener permission settings must be tested as a set: [Vault 1.20.4 listener source](https://github.com/hashicorp/vault/blob/v1.20.4/command/agentproxyshared/cache/listener.go) only supplies socket ownership configuration when mode, user, and group are all present; do not assume setting mode alone takes effect.

**Lifecycle risk:** upstream marks Agent API proxy deprecated, although functional. Pin and exercise the selected Agent release's combined proxy/templating behavior. Do not silently replace Agent with Vault Proxy: Proxy alone does not fulfill this design's file-rendering contract. A later removal requires an explicit migration decision; adding two daemons now is unnecessary.

### Vault roles and least privilege

Bind distinct Kubernetes auth roles to the **actual rendered** service-account names and one exact namespace; no wildcard namespaces/accounts. Audience `vault`; renewable service tokens, e.g. TTL 1h/max TTL 4h. PKI roles allow only service-specific DNS names, `allow_bare_domains=true`, subdomain/glob/wildcard/any-name/IP issuance disabled unless explicitly needed. ServerAuth only suffices for these listener certificates. Defaults: ECDSA P-256, 24h TTL/72h max, following Terraform's issuer split; production root CA lifecycle stays operator-managed.

| Policy | Allowed paths/capabilities |
|---|---|
| Common workload | `auth/token/lookup-self`: read; `auth/token/renew-self`: update; `sys/leases/renew`: update. No broad `sys/*`, token creation, lease enumeration or revoke privileges. |
| Permesi | `database/creds/permesi`: read; `secret/permesi/data/config`: read; `transit/permesi/datakey/plaintext/totp`, `transit/permesi/decrypt/totp`: update; `pki-int/issue/permesi-runtime`: create/update; `pki-int/cert/ca_chain`: read. |
| Permesi, OIDC enabled only | `transit/permesi/keys/oidc-signing`: read; `transit/permesi/sign/oidc-signing`: update. No rotation/export/config/delete. |
| Genesis | `database/creds/genesis`: read; `transit/genesis/keys/genesis-signing`: read; `transit/genesis/sign/genesis-signing`: update; `pki-int/issue/genesis-runtime`: create/update. |

Agent identity combines that service's runtime and PKI permissions: an application able to use its socket has those permissions. This is a per-pod identity, not an additional isolation boundary inside a pod. Public CA access is not secret sharing. Negative tests must exercise cross-service credential/KV/signing/PKI denial.

For in-cluster Vault, mount its own API-audience service-account JWT at the normal location and grant **only Vault's SA** TokenReview authority (a narrowly scoped ClusterRole, or upstream `system:auth-delegator`). Configure Kubernetes host and let Vault re-read its local reviewer token; do not write an expiring `kubectl create token` result permanently into Vault config. External Vault needs a separately documented renewable reviewer strategy and API/CA connectivity. See [reviewer-token lifecycle](https://developer.hashicorp.com/vault/docs/auth/kubernetes#use-local-service-account-token-as-the-reviewer-jwt).

## 4. M-QS: script quickstart and real-dependency integration

### Dependency selection and reusable implementation

Use a small development-only chart at **`scripts/quickstart/chart/`**, named `permesi-quickstart`. It owns official-image PostgreSQL and Vault workloads, their Services/RBAC, canonical bootstrap scripts under `files/`, and ordinary bootstrap Jobs. The top-level `scripts/quickstart/install.sh` installs this chart, waits for bootstrap, then installs the existing application charts. `scripts/quickstart/verify.sh` exercises the resulting application. No Terraform binary/state is required: translate the inspected Terraform semantics into explicit idempotent Vault CLI operations.

This placement is intentional: M-UQ can depend on the **same chart and scripts**, using `file://../../scripts/quickstart/chart`, rather than copy shell/SQL logic into the umbrella. Chart packages include their bootstrap assets; operators do not need a checkout at runtime.

| Candidate | Decision |
|---|---|
| Official `postgres:18` patch/digest, in-chart StatefulSet | Choose. Matches current application schema CI; no operator/CRD or Bitnami image dependency. Nonroot PostgreSQL identity, dedicated writable PGDATA, restricted security context; `emptyDir` by default. |
| Bitnami PostgreSQL / `bitnamilegacy` | Reject as the default. Availability changed in 2025; legacy archive receives no updates. Do not silently swap to unmaintained images. [Upstream announcement](https://github.com/bitnami/containers/issues/83267). |
| CloudNativePG | Good production operator option for the manual guide; too much cluster-wide installation/ownership for a disposable quickstart. |
| Official HashiCorp Vault Helm chart, injector off/dev on | Viable but adds another dependency and configuration surface. Use a minimal dev-only Deployment with official `hashicorp/vault` image instead; do not reimplement production HA/unseal/storage. |
| Persistent single-node Vault as default | Reject. Unseal keys, recovery/backup and root-token custody would make a misleading production-looking quickstart. External production Vault remains separate. |

Pin all image patch versions/digests and source checksums in a quickstart lock manifest. Resolve published images during implementation; do not invent digests in documentation. Match architecture to available application images: current backend Dockerfiles default to x86_64-musl; any-cluster means an appropriate Linux/amd64 node or separately verified supplied images, not unverified multi-arch support.

### Bootstrap credentials and the “everything in Vault” boundary

All **steady-state application secrets**, private TLS keys, PKI issuers, seed/pepper and DB credential issuance belong to Vault. Backend pods get no AppRole/DB/TLS Secret and no Vault root token. Public trust anchors may be ConfigMaps.

Vault and PostgreSQL cannot bootstrap their own first credentials from an uninitialized Vault. The disposable profile therefore has an explicit **bootstrap-only exception**: generated random dev Vault root credential and PostgreSQL administrator/owner passwords in narrowly mounted Kubernetes Secrets, never literal chart values/NOTES/ConfigMaps or committed fixtures. PostgreSQL and Vault bootstrap Jobs receive only their respective required inputs; application SAs cannot read them. Dev Vault must retain its root bootstrap credential for reruns; do not claim this is a zero-Kubernetes-Secret or production-safe deployment. Production bootstrap uses operator-held credentials outside Helm, and no such dev Secrets are created. No TLS private key is put in a Kubernetes Secret in either recommended path.

For direct Helm installs, a short-lived bootstrap credential-creation Job can generate these Secrets with release-scoped Role/RoleBinding; created Secrets must have release labels and an explicit uninstall/retention policy. Disable that Job's credentials after successful bootstrap where possible. Existing-secret input is available for operators who provision dev credentials themselves. Avoid Helm `randAlphaNum` secret values: Helm release history stores rendered Secrets and upgrades can silently rotate them. Development seed/pepper must be generated **inside Vault bootstrap**, not by Helm.

### Command contract

Proposed entry points (commands to implement, not present-day commands):

```sh
# Uses current context; creates only release-scoped development resources.
bash scripts/quickstart/install.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --acknowledge-development \
  --app-source ../permesi

# Optional explicit new-cluster mode; rootless Podman via KIND_EXPERIMENTAL_PROVIDER.
bash scripts/quickstart/install.sh --kind permesi-dev --acknowledge-development

bash scripts/quickstart/verify.sh --namespace permesi-quickstart --release permesi
```

- Require development acknowledgement and an explicit resolved kube context; print context/namespace, not credentials. Never delete an existing cluster or namespace. Existing-cluster mode must not require Kind or a container runtime on the host. Containerized tooling may supply Helm/kubectl; local examples use `hc` where appropriate.
- Namespace/release parameterization must generate DNS, SANs, DSNs, ServiceAccounts, issuer/audience and browser URLs consistently. Do not use `tpl` against arbitrary user values or rename existing production Services.
- Use bounded waits and fail on each unsuccessful stage. Default leaves a failed installation for diagnosis; cleanup removes only resources created by this invocation, with explicit teardown. CI can opt into cleanup. Sanitize diagnostics: no Secret dumps, JWTs, admission tokens, DB credentials or PEM key contents.
- Input schemas are canonical `permesi/db/sql` from a selected immutable application commit matching the tested image contract. With `--app-source`, package the include tree into split ConfigMaps and record revision; require explicit acknowledgement for dirty/local source. Without it, fetch a pinned archive/checksum, never branch HEAD. Supply all `\ir` relatives intact. Each ConfigMap must stay below Kubernetes object-size limits.
- The helper chart also supports fetching the pinned application archive in an init container with checksum verification for a pure Helm install, or mounting existing SQL ConfigMaps for air-gapped/local installs. Use a pinned image with verified HTTPS CA, download, tar and checksum tooling; no runtime package installation. Download failure is fatal, not a fallback to a different schema revision.

### Ordered bootstrap

Implement the main bootstrap as one Job with ordered init containers: schema acquisition → PostgreSQL-image SQL bootstrap/verification → main Vault-image CLI bootstrap. This enforces SQL-before-Vault-role provisioning without an extra controller or polling another Job. Mount administrator credentials only into the SQL container; mount Vault bootstrap credential and DB-manager inputs only into the Vault container. Each image supplies its own native CLI; no custom toolbox image or runtime package installation is required. The separate credential-creation Job produces prerequisites that these pods mount.

1. Create dedicated namespace/resource labels and SAs. Vault review RBAC may require a cluster administrator; preflight permission and allow a pre-created binding. Do not grant TokenReview to backend or bootstrap service accounts.
2. Start PostgreSQL 18 and dev Vault, ClusterIP only, no public Ingress/NodePort. Dev mode is in-memory and loses keys/seeds on Vault recreation. Keep database and Vault state lifecycles coupled: retained DB + lost Vault is **not recoverable by generating a fresh OPAQUE seed**. Reject that rerun; require explicit dev reset or a valid restore. Default persistence disabled for both.
3. Run SQL bootstrap as administrator against `postgres`, with `ON_ERROR_STOP=1`. Pre-create `vault_permesi` and `vault_genesis` using generated strong passwords so `00_init.sql` does not select its `change-me` development fallback. Use a restrictive `.pgpass` in Job memory for administrator and both owners; `\connect` authenticates as each owner. PostgreSQL TCP uses password authentication, never global `trust`/empty-password auth. Mount the whole canonical SQL tree, then run `00_init.sql` and owner-authenticated `verify_permesi.sql`.
4. Preserve ownership boundaries: non-superuser `vault_*` owners/credential managers, NOLOGIN runtime roles, owner `CREATEROLE`, runtime-role ADMIN OPTION only as canonical bootstrap grants it, `pg_signal_backend` for revocation. Never run service schemas as runtime users or grant runtime CREATE/superuser/owner privileges. Schema creation is explicit dev bootstrap, not a new production migration hook.
5. Enable Vault `auth/kubernetes`, configure reviewer lifecycle, separate transit mounts, KV v2 `secret/permesi`, `database`, and `pki-root`/`pki-int`. Create root/intermediate once, sign intermediate, set chain/issuer URLs. Use exact actual Service DNS names plus explicit browser-facing hostnames in per-service PKI roles. Do not issue wildcard certificates to simplify naming.
6. Create transit keys/types and 30-day auto-rotation matching Terraform. Only create optional OIDC key/policy when OIDC mode is requested. Set nonexportability and no plaintext backup/deletion for signing keys. Generate and persist 32-byte standard-base64 `opaque_server_seed` and `mfa_recovery_pepper` only if the config is absent; if partially populated, stop rather than silently replace cryptographic identity.
7. Configure `database/config/{permesi,genesis}` using corresponding `vault_*` manager credentials, allowed role restricted to itself. Credential roles use `CREATE ROLE ... LOGIN ... VALID UNTIL`, `GRANT <service>_runtime`, renewal `ALTER ROLE ... VALID UNTIL`, revocation terminate sessions → revoke membership → drop role. Default TTL 1h/max 4h. Do not copy Terraform Enterprise-only rotation scheduling blindly into community dev Vault; root rotation must be explicit and bootstrap must not overwrite a rotated manager password on rerun.
8. Write exact policies/SA-bound auth roles from §3 last, after prerequisites pass. PKI availability/auth is the app startup gate. Record bootstrap source revision/completion as nonsecret metadata, but never trust that marker instead of checking state. Enable failure-on-error, not `command || true` for already-exists handling; verify existing mount/key types before reuse.
9. Install application stack with Agent mode, two replicas for integration, DSN placeholders, exact HTTPS Genesis Service URL and CA, matching issuer/audience, development outbox email mode and permitted reserved test domain. Test client UUID `00000000-0000-0000-0000-000000000000` is seeded by canonical dev bootstrap; expose it only as test configuration, never production onboarding.
10. Wait for real readiness and run §5. Re-run bootstrap/install and roll back/restart application pods without changing CA, transit key identity, OPAQUE seed, client UUID, or existing user data. Never automatically execute `reset_all.sql`.

**PostgreSQL TLS and maintenance:** base disposable profile may use internal plaintext PostgreSQL and HTTP dev Vault, loudly identified as development-only; real TLS is exercised on both application listeners and PASERK. Production validation is separate: Vault HTTPS, PostgreSQL `verify-full`/CA, external persistence/backups, and canonical `cron_jobs.sql` plus `check.sql` on a pg_cron-capable PostgreSQL deployment. Stock `postgres:18` does not supply this scheduler automatically. The quickstart verifier must report `verify_permesi.sql` and targeted Genesis/role checks, not claim `check.sql` passed. For short-lived dev sessions invoke canonical maintenance functions explicitly in verification; do not advertise the dev deployment as indefinitely maintained or production TLS-qualified.

### Browser usability and ingress

Default quickstart needs no ingress controller: provide a foreground `connect.sh` that port-forwards web HTTP to loopback and backend HTTPS to loopback ports. Use consistent browser hostnames with certificate SANs (e.g. `api.localhost`, `genesis.localhost`), matching CORS/frontend origin/OPAQUE server ID; document local DNS requirements. Export only the **public PKI CA** to a user-selected file and show browser trust instructions. Never disable certificate checking or change host trust silently. API smoke uses `--cacert` and explicit hostname resolution, not `-k`.

For production with no TLS Secrets, prefer TLS passthrough to the backend, or an operator-provisioned edge which obtains its own TLS files from Vault. The existing ingress-nginx termination example uses Kubernetes TLS Secrets and is **legacy/alternative**, not the new recommended path. Web's current nginx listener is HTTP-only: an external Vault-backed TLS edge is still needed for public HTTPS web hosting. Do not promise that backend Agent support magically supplies ingress/web certificates or database-server TLS.

## 5. Step 2 acceptance: actual Kind integration

Add a separate `real-dependencies` CI job that uses the exact quickstart install/verify entry points, not another bootstrap implementation. Keep current render/ct/Restricted-admission smoke distinct.

Trigger on chart, `scripts/quickstart/**`, integration CI and relevant example changes; update workflow path filters. **Do not gate this job solely on `ct list-changed`**, which can be empty for script-only changes. Checkout app SQL at the lock manifest commit with read-only credentials; use immutable published image digests or explicitly loaded locally built test images. Fork PRs must not need production credentials or publish anything. Pin a supported Kind node image and allow enough bounded startup time; test supported native sidecar versions separately when available.

Required scenarios:

1. Fresh bootstrap: schemas and exact owner/runtime grants, Vault mounts/types, two Ready replicas of each backend under Restricted PSA. Web serves `/config.js` with intended URLs/client/OPAQUE ID. No zero-replica substitute.
2. Actual Agent path: backend startup with no AppRole credentials, socket owned/accessed by configured UID, token JWT absent from backend mounts, rendered bundle includes one private key and valid leaf/chain. Do not print private material. Authenticated tokenless proxy lookup succeeds; supplied invalid operator token remains rejected (guards against `force`).
3. HTTPS: `/live`, `/ready`, Genesis `/paserk.json` and `/token` via trusted CA with correct SAN. Wrong CA and wrong hostname fail validation. Kubernetes HTTPS probes do not verify certificates and are not this proof.
4. Admission: provisioned client obtains real token; perform valid OPAQUE signup start (`POST /v1/auth/opaque/signup/start`) with `Origin`, allowed email and `X-Permesi-Zero-Token`; expect 200 and a decodable registration response. Missing/tampered token must fail; wrong issuer/audience profile must not accept it. Do not count a later arbitrary 400 as positive admission proof.
5. Prefer complete signup start/finish through the actual web/WASM client in a browser runner, then assert pending user and protected email outbox receipt in PostgreSQL. A small external smoke client may reuse the application's OPAQUE suite; do not invent a registration blob or fake verification email. Outbox signup is **not** verified-email login/OIDC-token E2E. If full signup cannot be exercised, report that limit explicitly while keeping successful signup-start/admission mandatory.
6. Restart/scale: delete only test backend pods, scale 2→3, restart Agent independently, and verify recovery with new/rotated projected JWT. Revoke an Agent auth token/DB lease in the isolated test; confirm documented fail-closed app recovery, rather than assume Agent repairs an existing pool automatically.
7. Rotation: use short test PKI TTL, observe a changed served certificate serial before expiry without backend pod restart; allow issuance threshold plus >10s reload margin. Keypair/chain remain valid. Test Agent restart does not leave a dead socket. CA change requires an explicit rollout and is a separate case.
8. Split trust: requests through each service's proxy to the other service's DB/KV/signing/PKI role are denied. Especially Permesi → `transit/genesis/sign/genesis-signing` and Genesis → `secret/permesi/data/config`.
9. Repeat installation and application Helm upgrade preserve database records and cryptographic identity; failed/partial bootstrap does not silently regenerate seeds. Confirm no application TLS Secret exists. Exercise non-default release/namespace as a second case.

Collect rollout states, sanitized events, status codes and certificate serial/expiry evidence. Default Kind CNI does not prove NetworkPolicy enforcement. Production SMTP, OIDC authorization/code/PKCE, DB `verify-full`, CA-root rotation and shutdown under load are separate named qualifications, not implied by this gate.

## 6. M-UQ: optional umbrella quickstart

After M-QS passes, add a dependency on `permesi-quickstart` with alias `quickstart`, condition `quickstart.enabled`, and local repository `file://../../scripts/quickstart/chart`. Vendor it through normal Helm dependency packaging/lock handling. No Bitnami or operator dependency.

Add umbrella `quickstart` values:

- `enabled: false`, `acknowledgeDevelopment: false`; fail if enabled without acknowledgement.
- `vault.mode: dev` only; `postgresql.persistence.enabled: false`, single replicas, ClusterIP only. Reject public exposure/production mode and unsupported retained-DB/dev-Vault combinations, not just NOTES warnings.
- Locked image/source inputs, `bootstrap.existingCredentialsSecret` alternatives and `schema.{sourceUrl,sha256,revision,existingConfigMaps}` contract from M-QS.
- Explicit service identities/SANs/database endpoints needed by the bootstrap chart. Wrapper generates one complete values file for selected namespace/release; a documented fixed-name manual profile is also provided.

**Do not mutate sibling subchart values with template `set` or render-order tricks.** Umbrella templates cannot reliably derive child values for their sibling deployments. `quickstart.enabled` brings dependencies/bootstrap; the supplied quickstart profile also explicitly configures `permesi`, `genesis`, and `web` using their existing/new public values. Validate at parent scope that these values agree with bootstrap SA names/roles, service DNS, DSNs, Agent flags and seed client. This avoids hidden production naming changes and still permits a one-command script/Helm-profile installation.

Bootstrap Jobs are ordinary resources with bounded deadlines, retries only for readiness, and no post-install hook. A post-install hook plus `helm --wait` would deadlock while apps wait for PKI/database bootstrap. Jobs can run alongside app Deployments; Agent startup gates app launch until auth/PKI setup completes. Use revision/config-hashed Job names for rerunnable upgrades and explicit ownership/cleanup of old Jobs; schema upgrades remain explicit and dev-only. `helm --wait --wait-for-jobs` is the required direct-install invocation. Test a failed Job produces failed install, not a release that appears healthy.

Loud NOTES must state in-memory Vault/data loss, bootstrap Secret exception, no backups/HA/scheduler guarantee, no production support, trust/port-forward steps, teardown scope and the external-infrastructure production path. Helm cannot prevent a determined operator deploying dev mode into production; the two explicit flags, validation and no public exposure prevent accidental activation, not malicious misuse.

## 7. M-APP: separate application changes

### 5a — Permesi Vault base URL

Add Permesi `approle_login_url` semantics: HTTP(S) origin with empty or `/` path → standard `/v1/auth/approle/login`; explicit existing non-root login URL → preserve verbatim. Both wrapped and direct SecretID paths use it. Socket mode bypasses normalization. Prefer a narrowly scoped Permesi helper unless sharing truly removes duplicate logic without changing Genesis compatibility. Do not normalize custom auth mounts to the standard mount, discard path/query components, or alter `vault.url` globally for unrelated API calls.

Acceptance: real Vault login from base and standard full endpoint, existing custom AppRole mount endpoint, wrapped-token single-use scenario, unchanged Agent mode; malformed/unsupported URLs fail rather than choosing a guessed endpoint. Regression coverage for trailing slash and explicit path preservation. Run LSP references before exported API changes.

### 5b — native Kubernetes auth decision and alternative contract

**Recommendation: not worth implementing for this adoption path.** It adds a second token lifecycle and puts JWTs/Vault tokens into the application without removing the PKI Agent. The brief explicitly asks for this decision; the lead should record acceptance rather than claim native auth was implemented. Agent mode fulfills Kubernetes authentication for the deployment. Keep this a separable opt-in application milestone only if native/no-proxy operation is independently desired.

If approved, implement in both services consistently:

| CLI | Environment (both service prefixes) | Contract |
|---|---|---|
| `--vault-auth-method` | `PERMESI_VAULT_AUTH_METHOD`, `GENESIS_VAULT_AUTH_METHOD` | `auto` default: existing socket→Agent, TCP→AppRole. Explicit `kubernetes` requires TCP; no automatic fallback to another auth mode. |
| `--vault-kubernetes-auth-mount` | `PERMESI_VAULT_KUBERNETES_AUTH_MOUNT`, `GENESIS_VAULT_KUBERNETES_AUTH_MOUNT` | `kubernetes`; relative auth mount, no `/v1/auth/` prefix. |
| `--vault-kubernetes-role` | `PERMESI_VAULT_KUBERNETES_ROLE`, `GENESIS_VAULT_KUBERNETES_ROLE` | Required in Kubernetes mode, not AppRole role ID. |
| `--vault-kubernetes-token-path` | `PERMESI_VAULT_KUBERNETES_TOKEN_PATH`, `GENESIS_VAULT_KUBERNETES_TOKEN_PATH` | Default `/var/run/secrets/kubernetes.io/serviceaccount/token`; charts should use an explicit audience-scoped projection instead. |

POST JSON `{role,jwt}` to `/v1/auth/<mount>/login`, validate token/lease/renewability, read JWT afresh for each login, and reject AppRole flags in Kubernetes mode. Never log JWT or token. Token renewal failure must trigger re-login; not an AppRole attempt or indefinite use of an invalid token.

This is not just adding a login function: `GlobalArgs.vault_token` and renewal tasks currently **clone** `SecretString` (`crates/service_utils/src/globals.rs:18-35`, `vault/renew.rs:81-82,144-146`). In-place re-login requires one shared renewable auth-session source consumed by every KV/transit/DB caller; replacing one clone is broken. Preserve explicit operator-supplied token precedence. DB leases issued under the old token may be revoked, so failed pool/lease recovery must still restart and reacquire credentials. The lower-risk alternative is bounded fail-closed restart followed by fresh startup Kubernetes login, but that is restart-based re-login, not seamless live token replacement. If native live re-login is approved, scope shared state/callsite migration and test it explicitly rather than promising it from a CLI-only patch.

Acceptance if implemented: startup with projected token only; rotated JWT used on subsequent login; max-TTL/revocation renewal failure reauthenticates; every Vault caller uses replacement token; revoked DB credentials recover; wrong audience/role/namespace/SA denied; AppRole and Agent regressions unchanged. Native auth is not part of M-VA/M-QS's critical path.

### 5c — nginx security headers

Use a single application-owned snippet for the four existing security headers and include it in the server and every location that declares `add_header`. Copy the snippet in `apps/web/Dockerfile`. Preserve cache directives and response status behavior. Do not depend on newer `add_header_inherit merge` while the image uses floating `stable-alpine`; do not add unrelated CSP/HSTS changes.

Run the actual image/nginx configuration against `/healthz`, `/config.js`, `/index.html`, SPA fallback, an existing fingerprinted asset, a nonfingerprinted asset, a missing asset/404, and POST/405. Assert each of the four headers and existing cache behavior. Fix before/after evidence should include a location that currently loses inherited headers.

### 5d — image signing and digest publication

Keep current digest outputs, `IMAGES` manifest and digest-preserving release promotion. In candidate image creation, sign each `ghcr.io/permesi/<service>@sha256:...` with keyless Cosign and emit OCI build-provenance attestations with `subject-name`, `subject-digest` and registry push. Grant only that job `id-token: write`, `attestations: write`, `packages: write` as needed. Pin tooling/actions according to repository convention. Existing frontend/file signatures remain independent.

Release promotion should verify signer workflow/repository/issuer and expected source commit against immutable digest before tagging/dispatch. Signing failure blocks a candidate/release; do not fall back to tags. Retain trusted signature/attestation references through promotion within the same repository. Add verification instructions that constrain GitHub OIDC issuer and exact workflow identity, not unrestricted certificate identity regexes. D1 and local implementation must not publish/sign remotely without explicit authorization; actual GitHub OIDC publishing verification requires an authorized workflow run and must be reported as such.

## 8. M-DIG: digest values and release bump wiring

For each backend/web `image` add `digest: ""`, schema pattern `^$|^sha256:[0-9a-f]{64}$`. A chart-local image helper renders `repository@digest` when set, otherwise the exact existing `repository:tag`; keep `tag` for operator readability/backward compatibility. Agent image uses the same precedence inside its own helper; development dependency images follow the same rule. Tag changes do not override a nonempty digest: document clearing/updating it.

Umbrella managed image blocks gain `digest` fields. Update `scripts/bump-release.sh` to accept validated per-service digests while retaining its existing one-version invocation. Validate **all inputs before any mutation**. App releases write tags and digests to standalone and umbrella values together; a tag-only release must explicitly clear previous digests, never carry a stale digest into a new version. Chart-only releases retain all image identities unchanged.

In `release-bump-pr.yml`, read the event JSON/inputs through environment variables or a parser, not interpolated shell source. Consume `images.permesi.digest`, `images.genesis.digest`, `images.web.digest`; require the expected repositories, matching tags/version and a valid source SHA for repository dispatch. Require either all three valid digests or explicit legacy/tag-only mode, never a partial silent mix. Manual dispatch exposes three optional digest inputs plus explicit tag-only acknowledgement. Include digest/source identities in PR body. Existing automated merge/publish behavior is not authorization to execute it in this session.

Render/test standalone and umbrella digest precedence, tag fallback, malformed digest, mixed/empty payload and injection-shaped invalid values. Exercise bump script on a disposable checkout including pre-existing digests and a chart-only version greater than appVersion. Current charts are 0.4.4 with appVersion 0.4.3: do not regress chart versions on the next app bump; accept an independent chart-version argument if needed rather than assume app version always exceeds chart version. Rebuild umbrella dependencies after final component edits so packaged children are not stale.

## 9. Milestones, ownership and validation

All commands below are **planned acceptance commands**. Builders should create their owned fixtures/entry points; do not report these as already run. Use `/tmp/permesi-tools/hc` from chart repo root when host CLIs are unavailable. Checks that mutate clusters run only in the authorized isolated test namespace/cluster.

| Milestone | Exclusive ownership / dependencies | Acceptance and command surface |
|---|---|---|
| **M-VA** | `charts/permesi/**`, `charts/genesis/**`, except docs assigned to M-DOC. Own Agent values/schema/templates/tests. Initial wave; shared image/digest edits wait for handoff below. | `hc helm lint charts/permesi -f charts/permesi/ci/ct-values.yaml`; Genesis equivalent; `hc helm unittest charts/permesi` and Genesis. Render Agent fixture with `--kube-version 1.29.0` and negative 1.28; run actual socket/probe/config startup and rotation cases through M-QS. Disabled mode retains old rendering. |
| **M-QS** | `scripts/quickstart/**` including reusable helper chart/bootstrap files, `.github/workflows/charts-ci.yml`, new `scripts/ci/real-dependencies.sh` if needed. Does not edit backend/umbrella charts or application source. Can develop alongside M-VA against §3 contract; runtime integration waits for M-VA. | `bash scripts/quickstart/install.sh ... --acknowledge-development`; `bash scripts/quickstart/verify.sh ...`; two replicas, successful admission signup start, negative trust/privilege cases, rerun/restart/rotation. CI script-only changes trigger gate. Plain PostgreSQL scheduler/TLS limits reported accurately. |
| **M-UQ** | `charts/permesi-stack/**` including Chart.yaml/lock, helper dependency packaging and dev fixtures, except README assigned to M-DOC. **After M-QS**, using its chart without copies. No writes to `scripts/quickstart/**`. | `hc helm dependency build charts/permesi-stack`; `hc helm template ... -f <quickstart-profile>`; reject enabled-without-ack; `hc helm upgrade --install ... --wait --wait-for-jobs`; run M-QS verifier against umbrella-installed result and repeat upgrade. Disabled mode has no PostgreSQL/Vault/bootstrap resources. |
| **M-DIG** | `.github/workflows/release-bump-pr.yml`, `scripts/bump-release.sh`, new release test fixtures; additionally image values/schema/helper/deployment lines and dedicated digest tests in all three components plus umbrella managed values **only after explicit ownership handoff from M-VA/M-UQ**. | `hc helm unittest` on affected charts; disposable-checkout bump script for full digests/tag-only/invalid payload, then render all image references. Validate no stale child packages and no chart-version regression. No release workflow dispatch/push. |
| **M-DOC** | Root README, all chart READMEs, `docs/operations.md`, new manual guide and `docs/examples/*`; no templates or release script. Existing D1 plan remains architect-owned during D1. Can draft in parallel; finalize after runtime acceptance. | Render legacy production profile unchanged and new Agent profile; execute manual commands against isolated resources, then verifier. Explain all trust/credential exceptions, Kubernetes minimum, dev data loss, ingress/web boundary, schemas, upgrade/rotation, signing and digest precedence. |
| **M-APP** | Separate feature branch/worktree in `permesi/`: 5a `services/permesi/src/{vault,cli}` and focused tests; 5c `apps/web/nginx*`, Dockerfile and existing applicable smoke coverage; 5d `.github/workflows/deploy.yml`, associated workflow docs/verification tooling. Native 5b is a separate lead decision, not implied here. | Focused `cargo test --locked -p permesi` Vault tests plus real Vault base/custom-endpoint login; actual nginx HTTP header smoke before/after; workflow validation and local signature-verification command validation. Authorized CI is needed for real OIDC signing/publication evidence. No chart-repo writes. |

**Non-overlap rule:** never start M-DIG's chart edits concurrently with M-VA or M-UQ. Its release-workflow/script slice can run earlier, but component/umbrella file ownership transfers only after those builders finish. M-DOC alone owns prose/README edits; functional builders report required docs changes to it. M-QS's helper chart stays owned by M-QS when M-UQ adds it as a dependency. Each concurrent writer uses an isolated worktree. The lead owns integration/version bump decisions and final dependency rebuild; no unassigned writer edits shared Chart.lock/archives.

Suggested sequence: parallel M-VA + M-QS + M-APP + M-DOC draft → real-dependency gate → M-UQ → M-DIG chart handoff → combined renders/runtime upgrade and independent review → docs finalization. Reviewers receive requirements/diff, not builder reasoning. Stop after acceptance and no confirmed P0/P1 defects; do not expand into a general Vault/operator rewrite.

## 10. Manual guide outline and remaining risks

M-DOC's step-by-step guide must cover:

1. Supported cluster version/architecture, least-required RBAC, external production versus disposable quickstart choice.
2. PostgreSQL databases/owners/runtime grants, full SQL include ordering, authenticated owner connections, version compatibility, production scheduler/backup prerequisites.
3. Vault Kubernetes reviewer configuration, exact SA/namespace/audience roles, separate policies/transit/KV/database/PKI setup, issuer SANs and CA trust bootstrapping.
4. Agent values, volume permissions and startup gate; production HTTPS to Vault and DB; private keys never synchronized to Kubernetes Secrets.
5. Matching service DNS and PASERK trust, frontend URLs/CORS/OPAQUE ID, provisioned Genesis client and email mode.
6. Install, trusted HTTPS checks and admission/signup smoke, browser CA trust, optional Vault-backed edge; no assertion that HTTP web nginx is already publicly TLS-enabled.
7. Leaf certificate automatic reissue/reload versus CA restart, JWT/Agent restart, DB lease fail-closed recovery, explicit schema upgrades and backup/rollback limitations.
8. Digest selection/signature verification, restricted diagnostics, complete scoped teardown and dev state-loss warning.

Remaining risks/implementation gates:

- Agent proxy deprecation: selected pinned image must pass combined templating, Unix CLI probe, UID/socket permission and restart tests; no compatibility claim from current docs alone.
- Exact app image ↔ schema revision compatibility is not established by chart appVersion alone. Lock and test them together; do not install today's `sandbox` schema blindly with an older image and call it supported.
- Dev Vault HTTP and bootstrap Secrets are explicitly outside the secure production profile. A literal requirement for no bootstrap credentials outside Vault cannot be satisfied before Vault exists; do not obscure that trust root.
- Dev Vault loss with retained PostgreSQL loses cryptographic identity, not merely configuration. No idempotent bootstrap may manufacture replacement keys and call the old database recovered.
- Production no-TLS-Secret policy includes the edge; retaining the old Secret-backed ingress example as the recommended Agent path would violate it. Edge integration remains operator-specific and must be explicit.
- Root/intermediate rotation is not solved by leaf reload: PASERK roots are startup-loaded; roll with overlapping trusted roots before issuer changes.
- Current Agent startup does not make backend readiness a comprehensive Vault-signing check; verify actual Genesis token issuance and negative policy behavior.
- Native Kubernetes auth would require a complete shared-token lifecycle migration, not only flags; if approved, it needs a distinct design/implementation review and real renewal-failure test.
- Kind observations and a Helm render are not real-dependency proof. D1 delivers a verified-source design; M-VA/M-QS/M-UQ remain implementation milestones, and remote signing/publication remains unexecuted.

## 11. Lead review (D2) — approved scope

Approved as designed, with these decisions:

- **M-VA**: approved. Native sidecar, Kubernetes ≥ 1.29 required only when `vault.agent.enabled=true`. Defaults off; existing renders unchanged.
- **M-QS**: approved: `scripts/quickstart/` helper chart (official `postgres:18`, dev-mode `hashicorp/vault`), `install.sh`/`verify.sh`/`connect.sh`, and a `real-dependencies` CI job. Minimum runtime proof: two Ready replicas per backend in Agent mode under Restricted PSA, HTTPS `/paserk.json` + `/token` with the quickstart CA (wrong CA/hostname fail), Genesis token accepted by Permesi admission, split-trust denials, restart and leaf-rotation. A full OPAQUE signup through the WASM client is a stretch goal; if not achieved, report it as not verified.
- **M-UQ**: approved after M-QS, reusing its chart via `file://` dependency.
- **M-DIG**: approved; chart edits only after M-VA/M-UQ hand off.
- **M-DOC**: approved; drafts in parallel, finalized after runtime acceptance.
- **M-APP**: 5a and 5c already implemented on `permesi` branch `feat/k8s-hardening` (reviewer to check Genesis compatibility of the shared helper and the extra nginx cases in §7). 5d approved (keyless Cosign + OCI provenance in `deploy.yml`; remote signing evidence requires an authorized CI run).
- **5b native Kubernetes auth: deferred.** The Vault Agent path already provides Kubernetes auth, and native auth requires a shared token-lifecycle migration across all Vault callers (§7). Revisit only if a no-sidecar deployment mode is required.
