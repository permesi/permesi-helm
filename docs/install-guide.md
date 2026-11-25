# Permesi installation guide

Step-by-step manual guide for running the Permesi platform on Kubernetes.

Two paths are documented here:

- **Production** — externally operated PostgreSQL and OpenBao, chart-managed
  OpenBao Agent (Kubernetes auth + PKI certificate rendering). Recommended.
  AppRole/Secret and External Secrets Operator (ESO) paths remain supported but
  are not the primary walkthrough.
- **Disposable quickstart** — `scripts/quickstart/install.sh`, one command,
  cluster-local PostgreSQL + dev-mode OpenBao. Development only.

The charts deploy application 0.6 and later, which use OpenBao only; HashiCorp Vault is
no longer supported. Production steps below are source-derived operator
instructions, not a claim that this guide was run against production
OpenBao/PostgreSQL or an HTTPS edge. Use the application SQL revision tested with
your selected images; `scripts/quickstart/lock.json` records the pinned
application version and SQL commit. Do not substitute branch HEAD.
The production examples use release/namespace `permesi`/`permesi`; replace their
hostnames, networks, client ID and trust anchors for your environment.

## Disposable quickstart

Requires Bash, Helm, kubectl, Python 3, an explicit reachable kube context and a
Linux/amd64 node. Installation into an existing cluster needs no local Kind or
container runtime. Default helper setup preflights cluster RBAC creation rights;
an administrator can instead pregrant OpenBao-only TokenReview (§below). New
namespaces enforce Restricted PSA. Managed Agent requires Kubernetes ≥1.29 with
SidecarContainers.

```bash
bash scripts/quickstart/install.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --acknowledge-development
```

The default fetches the immutable SQL archive/checksum from
`scripts/quickstart/lock.json`; image pins are also in that file (the OpenBao and
PostgreSQL pins come from `scripts/quickstart/openbao-images.json`). PostgreSQL
19.0 and HTTP dev OpenBao 2.7.3 are internal ClusterIP workloads. Bootstrap runs
schema acquisition → authenticated owner SQL → OpenBao configuration before
application startup succeeds. Two replicas of each backend use Agent, real TLS and
exact SA-bound Kubernetes roles. No OpenTofu is needed.

Options:
- `--app-source /path/to/permesi` packages the complete `db/sql` include tree from
  a clean matching Git checkout. `--allow-dirty` explicitly accepts dirty/non-Git
  sources; that is not evidence of image/schema compatibility.
- `--kind permesi-dev` replaces `--context` to use/create a named Kind cluster;
  Kind/runtime are required only for that option. Never deletes an existing
  cluster. Existing-cluster mode is the tested path.
- `--deps-only` bootstraps only PostgreSQL/OpenBao; `--charts-dir` selects component
  charts; repeatable `--quickstart-values` supplies helper overrides.
- `--timeout 900` is the per-stage default. `--pki-ttl 2m` is intended for the
  verifier's bounded leaf-rotation exercise (default `24h`).
- `--cleanup` removes only a namespace/cluster created by that invocation on exit
  (success or failure); it refuses pre-existing namespaces. Without it, failed
  installs remain for diagnosis.

Custom `postgresql.service.name`/`port` and `openbao.service.name`/`port` values
propagate to generated application DSNs and Agent addresses. Installation,
verification and connection helpers resolve effective merged Helm values;
verification also supports the umbrella's `quickstart` values subtree. Invalid
settings fail rather than falling back to another endpoint or OIDC mode.

For **dependency-only** Helm bootstrap (not a full-stack substitute):

```bash
helm upgrade --install permesi-quickstart scripts/quickstart/chart \
  --namespace permesi-quickstart --create-namespace \
  --set acknowledgeDevelopment=true --wait --wait-for-jobs --timeout 900s
```

It fetches the locked SQL archive, or accepts
`bootstrap.schema.existingConfigMaps` with `sourceUrl: ""` for the full SQL
include tree. `bootstrap.services.*.serviceName` and
`bootstrap.kubernetesRoles.*.serviceAccount` must match any later applications.
Script install supplies its own complete wiring. For a complete Helm-only stack,
use the [umbrella profile](../charts/permesi-stack/README.md#quickstart-mode),
not the dependency-only command above.

### Namespaced installer with pregranted reviewer

Default `rbac.createTokenReviewBinding: true` creates a TokenReview-only
ClusterRole/Binding. Its namespace-safe hashed identity includes the complete
release/namespace, avoiding truncation collisions. The installer checks creation
authority before mutating namespace/SQL inputs.

For the fixed script/umbrella profile, a cluster administrator can pregrant only
the eventual OpenBao SA:

```bash
kubectl --context kind-permesi-helm-test create namespace permesi-quickstart
kubectl --context kind-permesi-helm-test label namespace permesi-quickstart \
  pod-security.kubernetes.io/enforce=restricted
kubectl --context kind-permesi-helm-test create clusterrole permesi-quickstart-pregranted-reviewer \
  --verb=create --resource=tokenreviews.authentication.k8s.io
kubectl --context kind-permesi-helm-test create clusterrolebinding permesi-quickstart-pregranted-reviewer \
  --clusterrole=permesi-quickstart-pregranted-reviewer \
  --serviceaccount=permesi-quickstart:permesi-quickstart-openbao
```

Using an operator-owned protected values file, the namespaced installer selects:

```yaml
# /secure/operator/quickstart-pregrant.yaml (helper-chart values)
rbac:
  createTokenReviewBinding: false
```

```bash
bash scripts/quickstart/install.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --acknowledge-development \
  --quickstart-values /secure/operator/quickstart-pregrant.yaml
```

The installer still needs normal namespace resource privileges and get access to
the target Namespace, but not cluster-RBAC creation. Generated credential Job
Role/RoleBinding remain enabled unless an existing credentials Secret disables
that Job. For umbrella values use `quickstart.rbac.createTokenReviewBinding=false`.
For other names, bind the actual `<helper-fullname>-openbao` SA in the exact target
namespace; never app/bootstrap/credential SAs.

Pregranted grants are operator-owned. Before changing an existing Helm-owned grant
to false mode, establish a distinct operator-owned grant: Helm removes its own
binding on upgrade. After teardown the administrator removes these exact grants:

```bash
kubectl --context kind-permesi-helm-test delete clusterrolebinding permesi-quickstart-pregranted-reviewer
kubectl --context kind-permesi-helm-test delete clusterrole permesi-quickstart-pregranted-reviewer
```

### Verify and connect

The full verifier needs curl and Cargo (or an executable `QS_ADMISSION_BIN` built
from `scripts/quickstart/admission`). Containerized Alpine tooling requires a
compatible static/musl binary. Run commands in the same tool environment/context
that can reach the cluster:

```bash
bash scripts/quickstart/verify.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi

bash scripts/quickstart/connect.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi --ca-out quickstart-ca.pem
```

`connect.sh` stays in the foreground and stops its own forwards on Ctrl-C:
- web `http://localhost:8080`;
- API `https://api.localhost:8443`;
- Genesis `https://genesis.localhost:9443`.

Resolve `api.localhost` and `genesis.localhost` to `127.0.0.1`. Import only the
exported **public** root CA into a disposable browser profile; the script neither
modifies trust nor disables verification. For curl:

```bash
curl --cacert quickstart-ca.pem --resolve genesis.localhost:9443:127.0.0.1 \
  https://genesis.localhost:9443/paserk.json
```

The quickstart uses test client `00000000-0000-0000-0000-000000000000`,
OPAQUE server ID `api.localhost`, allowed dev domain `example.test`, and outbox
email (no SMTP delivery). `verify.sh --exercise-lifecycle` mutates only this dev
installation: wrong-claim negatives, leaf rotation, Agent restart, application DB
lease revocation/recovery, backend replacement and scaling. Use a short PKI TTL
at install for that run. The corrected verifier tracks each exact issued
username/lease, requires synchronous revocation and disappearance of that role,
and owns dynamically allocated loopback forwards rather than probing fixed ports.

Verification requires a deployed helper Helm release. A retained latest bootstrap
Job must have succeeded; after normal Job collection, all durable SQL/OpenBao,
manager-rotation and service-policy checks remain mandatory before runtime checks
run. A failed Helm release remains a failure even after its Job disappears.
Completed retries are accepted; failed or incomplete Jobs are rejected.

With `bootstrap.oidcSigning.enabled=false`, verification requires denial of
Permesi OIDC signing instead of requiring an RSA key. Disabling OIDC on an existing
installation preserves its signing key while removing signing permission.

The direct port-forwards are useful for API tools. Browser cookie sessions need
a same-origin edge, or HTTPS frontend/API hosts on the same site. Mixing the HTTP
web forward with cross-site HTTPS API hosts does not establish browser-session
compatibility. Preserve `SameSite=Lax`, secure cookies and WebAuthn origin checks;
configure the frontend/CORS/runtime URLs consistently instead of relaxing them.

For a Helm-only umbrella install, explicitly map its helper:

```bash
bash scripts/quickstart/verify.sh --context kind-permesi-helm-test \
  --namespace permesi-quickstart --release permesi \
  --helper-release permesi --helper-fullname permesi-quickstart
```

Earlier verifier qualification established pool-lease recovery, replacement,
scaling and native test-client OPAQUE; it did not establish native OpenBao login or
browser/WASM signup. The candidate runners below exercise those additional paths;
their failures remain qualification blockers.
Natural projected-JWT expiry/rotation, CA-root rotation and production durability
remain separate qualifications; see
[operations](operations.md#11-quickstart-qualification-and-known-boundaries).

### Qualifying candidate application images

Build Permesi and Genesis with telemetry using their application Dockerfiles,
and build web from a freshly compiled distribution. Load these images into an
owned disposable Kind cluster. Record the imported manifest digests and ensure
containerd has both tag and repository-at-digest references; `imagePullPolicy:
Never` must resolve the exact loaded images. Both service `--version` outputs
must identify the application commit being qualified.

`scripts/ci/prepare-application-fixture.py` copies the charts and tooling outside
the Helm checkout and replaces only the fixture's application image/source pins.
Supply all three actual `repository:tag@sha256:...` references:

```bash
python3 scripts/ci/prepare-application-fixture.py \
  --app-source /path/to/permesi --destination /var/tmp/permesi-candidate \
  --image "permesi=$PERMESI_TEST_IMAGE" \
  --image "genesis=$GENESIS_TEST_IMAGE" \
  --image "web=$WEB_TEST_IMAGE"

QS_CONTEXT=kind-permesi-compat QS_NAMESPACE=qv-candidate \
  QS_APP_SOURCE=/path/to/permesi QS_ADMISSION_BIN=/path/to/quickstart-admission \
  bash /var/tmp/permesi-candidate/scripts/ci/real-dependencies.sh
```

The application checkout must be clean and match the fixture revision. Its actual
SQL files are packaged into ConfigMaps, so a passing older published-image gate
cannot stand in for candidate runtime proof. Committed default pins remain intact.

Run `scripts/quickstart/tests/real-auth-modes.py` with explicit context, absent
`qv-auth-*` namespace, application source, candidate `--charts-dir` and
`--admission-bin` to exercise Agent, native Kubernetes auth, AppRole and restoration
to Agent. It checks real HTTPS/admission, wrong-audience rejection without a DB
lease, and native token revocation with fail-closed application restart.

`scripts/quickstart/tests/real-browser-upgrade.py` accepts an explicit context,
absent `qv-browser-*` namespace, application source and generated `--fixture`.
It requires the application's Chromium/Node/NSS browser-runner image, selectable
with `--browser-image`. It packages the umbrella with external disposable helper
dependencies, imports only the public test CA into a disposable browser container,
and uses a loopback TLS edge that verifies backend TLS. Real signup, mailbox
verification, OPAQUE login, MFA and passkey creation run on published baseline
images; candidate upgrade must preserve persisted records and allow the existing
password and passkey to authenticate. The fixed embedded-quickstart profile and
its validation remain unchanged. These runners remove only their owned releases,
namespaces and test containers.

Qualification on 2026-10-26 used application sandbox commit
`6f32b5376806ff6ba259f1b2aeb1cffea706c3bc`, freshly built telemetry-enabled
backends and web, and canonical SQL. The real Agent lifecycle, native Kubernetes
auth, AppRole and packaged embedded umbrella passed. Browser upgrade preserved
the OPAQUE and passkey records byte-for-byte and password/MFA sign-in passed.
Full browser passkey qualification remains blocked: published baseline 0.4.3
registers a nonresident credential with the virtual authenticator, while login
requests a discoverable credential. The default browser runner rejects this
baseline explicitly. `--password-only` qualifies password/MFA and record
preservation, and explicitly excludes passkey authentication. Requiring resident
registration is an application authentication change outside these Helm fixes.

The application Rust security audit also remains blocked by
`crypto-bigint 0.5.5` (`RUSTSEC-2026-0387`). The published dependency chains still
require that version; normal `cargo upgrade`/`cargo update` did not resolve it.
No new audit exception, fork or backport is introduced by this qualification.

### Bootstrap secret exception and reset

Random PostgreSQL administrator/owner passwords and the dev OpenBao root credential
must exist before OpenBao can bootstrap. The helper creates a narrowly mounted
**bootstrap-only Kubernetes Secret**, retained after uninstall for safe reruns;
these inputs never reach application pods. Alternatively
`bootstrap.credentialsSecret` names a precreated Secret with keys
`postgres-admin-password`, `openbao-root-token`, `openbao-permesi-password`,
`openbao-genesis-password`. These remain the static canonical schema-owner inputs.
The helper creates separate `openbao_permesi_manager`/`openbao_genesis_manager` logins,
then immediately rotates their passwords through OpenBao after first configuration.
Steady-state manager passwords stay only in OpenBao. Existing configs are reused
only for the expected manager and exact allowed role; legacy owner-as-manager
configs require a manager-separated restore or explicit disposable reset, never
an automatic migration/password reset. Private application TLS keys stay in
memory volumes, never synchronized to Kubernetes Secrets.

Existing-Secret passwords preserve colon/backslash bytes via `.pgpass` escaping;
CR/LF are rejected before connecting. The OpenBao startup wrapper filters only
anchored root/unseal banner lines, streams remaining diagnostics and preserves
signals/exit status. The bootstrap correction report runtime-qualified these
behaviors, manager rotation/rerun and a restricted pregranted installation.

Both dependencies are ephemeral. Losing dev OpenBao while retaining **any**
application database (even empty) deliberately fails bootstrap; generating a new
OPAQUE seed cannot restore identity. Use an explicit full dev reset or a matching
restore, not an in-place OpenBao-image replacement.

---

## 1. Cluster, architecture and least-required RBAC

### Supported versions

- Any Kubernetes cluster that can run the charts (Helm 3.13+).
- **OpenBao Agent mode** (`openbao.agent.enabled: true`) requires
  **Kubernetes ≥ 1.29 with the `SidecarContainers` feature gate enabled**, because
  the Agent is a native sidecar (`initContainers[].restartPolicy: Always`) that
  must outlive the application container during graceful shutdown. Recommend
  **≥ 1.33**, where native sidecars are stable. This opt-in mode fails chart
  rendering on an older API server; disabled mode (the default) has no such
  requirement.
- Application images are `linux/amd64` (`ghcr.io/permesi/{permesi,genesis,web}`,
  0.6 or later).
  Use an amd64 node, or separately verified images.

### Architecture

| Component | Role |
|---|---|
| `permesi` | IAM service (Deployment/Service/Ingress/HPA/PDB/NetworkPolicy) |
| `genesis` | edge admission service (same operational patterns) |
| `web` | nginx-served UI; `/config.js` injected at runtime |
| `permesi-stack` | umbrella chart installing all three |

Backend containers are `scratch` images (no shell). The OpenBao Agent sidecar is the
only place shell probes, certificate rendering, and preparation happen.

### Least-required RBAC

- **Application ServiceAccounts need no RBAC.** They need no Secret read/list and
  no TokenReview permission; OpenBao authenticates the pod via the projected
  service-account token, and the Agent holds the resulting OpenBao token. In Agent
  mode set `serviceAccount.automount=false` (validated by the chart); an explicit
  audience-scoped token is mounted **only into the Agent container**. Optional
  native mode mounts its separate projection only into the application.
- **In-cluster OpenBao** needs `TokenReview` for its *own* ServiceAccount only — a
  narrowly scoped ClusterRole, or the upstream `system:auth-delegator` cluster role
  bound to OpenBao's SA alone. Do not grant TokenReview to backend or bootstrap
  ServiceAccounts.
- **External OpenBao** needs API connectivity, Kubernetes CA trust, a dedicated
  TokenReview-only reviewer SA and an explicitly refreshed short-lived
  TokenRequest JWT. A Kubernetes JWT is not renewable like a OpenBao token.
  Follow the complete provisioning/replacement procedure in §3.1.
- **Operators** need permission to create the namespace, ServiceAccounts, Secrets
  (legacy paths only), ConfigMaps (public trust anchors), and to write OpenBao
  policies/roles via the OpenBao API.

---

## 2. PostgreSQL: databases, owners, runtime grants

In the **production path**, both services require externally provisioned
databases; the application charts provision no production database/PVC.
There are **no application migrations**: apply schemas before the pods start.

### Version compatibility

Application CI runs against official **PostgreSQL 19**. Production requires a
pg_cron-capable deployment if you use the canonical scheduled jobs (`cron_jobs.sql`
+ `check.sql`); stock PostgreSQL does not provide pg_cron.

### Ownership model

- `openbao_permesi` / `openbao_genesis`: static non-superuser canonical schema owners.
  They own their service database/objects and authenticate schema bootstrap and
  maintenance. Do not configure OpenBao's rotate-root against these identities.
- `openbao_permesi_manager` / `openbao_genesis_manager`: separate non-owner
  `LOGIN CREATEROLE` credential managers used only by OpenBao's database engine.
  They receive own-DB CONNECT, pg_signal_backend and the matching runtime role's
  ADMIN membership with INHERIT/SET disabled; no schema/database ownership.
- `permesi_runtime` / `genesis_runtime`: `NOLOGIN` roles that hold all
  schema/table grants. OpenBao-minted short-lived login roles receive membership in
  the matching runtime role only — they never own objects, create schemas, or hold
  superuser privileges.
- OpenBao's database roles use `CREATE ROLE ... LOGIN ... VALID UNTIL` (creation),
  `ALTER ROLE ... VALID UNTIL` (renewal), and terminate-sessions → revoke-membership
  → drop-role (revocation). Default TTL 1h / max 4h.

### 2.1 Pre-create the canonical schema owners

Create the two static owners with strong, unique passwords **before** running
the canonical bootstrap, so `00_init.sql` does not fall back to its development
`change-me` password:

Use a TLS-authenticated administrator connection and interactive `\password`
(or a protected operator credential workflow), not real password literals in
shell history:

```bash
export PGSSLMODE=verify-full
export PGSSLROOTCERT=/path/to/postgresql-ca.crt
psql -X -v ON_ERROR_STOP=1 -h db.example.com -U postgres -d postgres <<'SQL'
CREATE ROLE openbao_permesi WITH LOGIN CREATEROLE;
\password openbao_permesi
CREATE ROLE openbao_genesis WITH LOGIN CREATEROLE;
\password openbao_genesis
GRANT pg_signal_backend TO openbao_permesi, openbao_genesis;
SQL
```

### 2.2 Apply the canonical include tree

Run `00_init.sql` once as a superuser with `ON_ERROR_STOP=1`. It creates the two
databases (owned by the OpenBao roles), the runtime roles, transfers object
ownership, and then reconnects as each authenticated owner to load
`01_genesis.sql`, `02_permesi.sql`, `seed_test_client.sql`, and
`verify_permesi.sql`. Do **not** independently reapply the three files as an
administrator or substitute `SET ROLE` — the script switches to fresh
owner-authenticated connections.

```bash
export PGPASSFILE=/secure/operator/permesi.pgpass
unset PGPASSWORD
psql -X -h db.example.com -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f db/sql/00_init.sql
```

A minimal `PGPASSFILE` (mode `0600`) includes administrator **and** owner entries;
do not set a single `PGPASSWORD` that would override them on `\connect`:

```
db.example.com:5432:*:postgres:<administrator-password>
db.example.com:5432:*:openbao_permesi:<strong-password>
db.example.com:5432:*:openbao_genesis:<strong-password>
```

In each `.pgpass` password field, escape literal `:` as `\:` and `\` as `\\`;
protect the file outside the repository and do not log its contents.

#### Separate credential managers after schema bootstrap

The canonical include tree creates the runtime roles. Then create independent
manager identities; do not change schema/table ownership or inherit runtime
privileges into these managers:

```bash
psql -X -v ON_ERROR_STOP=1 -h db.example.com -U postgres -d postgres <<'SQL'
CREATE ROLE openbao_permesi_manager LOGIN CREATEROLE NOSUPERUSER NOCREATEDB;
\password openbao_permesi_manager
CREATE ROLE openbao_genesis_manager LOGIN CREATEROLE NOSUPERUSER NOCREATEDB;
\password openbao_genesis_manager
GRANT permesi_runtime TO openbao_permesi_manager WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
GRANT genesis_runtime TO openbao_genesis_manager WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
GRANT CONNECT ON DATABASE permesi TO openbao_permesi_manager;
GRANT CONNECT ON DATABASE genesis TO openbao_genesis_manager;
-- 00_init.sql revokes PUBLIC connect on postgres; Genesis credential management
-- runs through that maintenance database (§3.5).
GRANT CONNECT ON DATABASE postgres TO openbao_genesis_manager;
GRANT pg_signal_backend TO openbao_permesi_manager, openbao_genesis_manager;
SQL
```

Keep administrator/schema-owner credentials in the protected operator workflow;
only each manager's initial password goes to its first OpenBao connection config.
The dev helper initially reuses the matching owner bootstrap password for its
new manager, then immediately rotates the manager. Production can start managers
with separate unique bootstrap passwords. Either way, owner passwords stay
static and credential-manager rotation must not change scheduler/schema owners.

### 2.3 Production scheduler (pg_cron) and verification

An operator `PGPASSFILE` authenticates the operator's psql connection; it does
**not** configure pg_cron's server-side execution. This guide chooses the
[upstream-supported background-worker mode](https://github.com/citusdata/pg_cron/blob/v1.6.8/README.md#ensuring-pg_cron-can-start-jobs)
instead of libpq job connections. It avoids rotating-password/HBA/peer-map
dependencies without granting runtime roles ownership or weakening TCP auth.

Install the PostgreSQL-major-compatible pg_cron extension package in the server
image/operator environment (for PGDG PostgreSQL 19, `postgresql-19-cron`).
Configure the following before registration and **restart PostgreSQL** through
its service/operator. Preserve other entries in `shared_preload_libraries`:

```conf
shared_preload_libraries = 'pg_cron'
cron.database_name = 'postgres'
cron.use_background_workers = on
cron.log_run = on
max_worker_processes = 20
cron.max_running_jobs = 4
```

The worker settings above are the isolated qualified values, not universal
capacity sizing: budget launcher, maintenance jobs, parallel queries and other
extensions. Restart-required settings are not applied by `pg_reload_conf()`.
With background workers, `cron.host` has no effect; workers initialize database
sessions as each registered job username without libpq/password authentication.
No server `.pgpass`, peer mapping or broad `trust` rule is needed for this mode.
Keep ordinary operator/application connections TLS/SCRAM-authenticated.

```bash
psql -X -h db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT name,setting,pending_restart FROM pg_settings WHERE name IN ('shared_preload_libraries','cron.database_name','cron.use_background_workers','cron.log_run','max_worker_processes','cron.max_running_jobs') ORDER BY name;"
psql -X -h db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 -f db/sql/cron_jobs.sql
psql -X -h db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 -f db/sql/check.sql
```

Require `cron.use_background_workers=on`, `cron.log_run=on`,
`cron.database_name=postgres` and no pending restart before declaring the mode
configured. The canonical SQL creates the extension in `postgres` and registers:

| Job | Database / static owner | Command / schedule |
|---|---|---|
| `genesis_tokens_rollover` | `genesis` / `openbao_genesis` | `SELECT genesis_tokens_rollover(7, 2);` at `5 0 * * *` |
| `permesi_cleanup_expired_tokens` | `permesi` / `openbao_permesi` | `SELECT cleanup_expired_tokens();` at `15 0 * * *` |

Do not change these usernames to the new credential managers. `check.sql` verifies
registration/schema, **not job execution**. Capture a baseline after registration
(and again after any manager-rotation event), then allow both scheduled jobs to
run and require successful completed executions after that baseline:

```bash
BASELINE="$(psql -X -w -h db.example.com -U postgres -d postgres -At \
  -v ON_ERROR_STOP=1 -c 'SELECT coalesce(max(runid),0) FROM cron.job_run_details')"
# Wait for the actual daily maintenance window before the following check.
psql -X -w -h db.example.com -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -v baseline="$BASELINE" <<'SQL'
SELECT j.jobname,r.runid,r.database,r.username,r.status,
       r.return_message,r.start_time,r.end_time
FROM cron.job_run_details r JOIN cron.job j USING (jobid)
WHERE r.runid > :baseline
  AND j.jobname IN ('genesis_tokens_rollover','permesi_cleanup_expired_tokens')
ORDER BY r.runid;
SELECT count(DISTINCT j.jobname) = 2 AS both_completed
FROM cron.job_run_details r JOIN cron.job j USING (jobid)
WHERE r.runid > :baseline AND r.status = 'succeeded' AND r.end_time IS NOT NULL
  AND j.jobname IN ('genesis_tokens_rollover','permesi_cleanup_expired_tokens')
\gset
\if :both_completed
\echo 'Both maintenance jobs completed after the baseline'
\else
\echo 'Maintenance execution is not yet qualified'
\quit 1
\endif
SQL
```

Inspect failed runs as failures, not just the eventual successful row. Also
observe intended state changes: Genesis creates the premade daily partitions and
drops expired dated partitions; Permesi removes retention-eligible rows while
retaining live sessions/tokens/exchanges. Do not create synthetic accounts or
accelerate cleanup on production just to make this check pass.

In a **disposable qualification database only**, bounded execution can be
accelerated without changing either canonical command, identity or database:

```sql
SELECT cron.alter_job(jobid, schedule := '5 seconds')
FROM cron.job
WHERE jobname IN ('genesis_tokens_rollover','permesi_cleanup_expired_tokens');
-- Restore both canonical schedules before running check.sql again.
SELECT cron.alter_job(jobid, schedule := CASE jobname
  WHEN 'genesis_tokens_rollover' THEN '5 0 * * *'
  WHEN 'permesi_cleanup_expired_tokens' THEN '15 0 * * *' END)
FROM cron.job
WHERE jobname IN ('genesis_tokens_rollover','permesi_cleanup_expired_tokens');
```

The isolated docs qualification used PostgreSQL 18.6 with package
`postgresql-18-cron 1.6.8-1.pgdg13+2` (SQL extension version `1.6`): both jobs
completed before/after replacement of both manager passwords, 12 successful runs
and zero failures. Partition creation/retention and six cleanup targets changed
as intended; live rows and canonical function/owner definitions remained intact.
Old manager passwords failed and new ones worked; static owner credentials stayed
unchanged. This used SQL password replacement, **not OpenBao rotate-root API calls**;
the bootstrap correction report separately exercised those APIs and reruns.
No production/managed-service/TLS/HA qualification is implied.

The canonical file's comments describe a different, local-libpq peer-mapping
alternative. Do not combine only half of that mode with password jobs: if workers
are unavailable, implement its complete socket `cron.host`, exact
`pg_ident.conf`/ordered `pg_hba.conf` peer rules and reload workflow instead.
That alternative was not runtime-qualified here. The disposable Helm quickstart
intentionally contains no pg_cron scheduler.

### 2.4 Schema upgrades and OAuth reapplication

Reapply the additive scripts (`02_permesi.sql` for the OAuth/refresh/credential
tables) as the existing schema owner with `ON_ERROR_STOP=1` **before** starting a
binary that exposes the new protocol routes. Reapplication preserves client
configuration, grants, and data. Helm rollback does **not** roll back schema or
data. Never run `reset_all.sql` outside dev/test.

### 2.5 PostgreSQL TLS

Use `sslmode=verify-full` plus a CA file mounted via `extraVolumes`/`extraVolumeMounts`
(see the production example). OpenBao's database connection URL must also use
`sslmode=verify-full` (or `verify-ca`) in production, with OpenBao configured to
trust the database CA.

---

## 3. OpenBao: reviewer, auth roles, mounts, policies, PKI

The application provisions OpenBao with its OpenTofu module,
`openbao/contrib/opentofu` in the permesi repository (encrypted state, write-only
database root passwords; see its README). That module targets AppRole/cert-auth
hosts; this section translates its contract into `bao` CLI steps for the
Kubernetes-auth deployment the charts use. Keep the two in step when either
changes. Set the environment first:

```bash
export BAO_ADDR="https://openbao.example.com:8200"
export BAO_TOKEN="<root-or-admin-token>"
# Only if OpenBao uses a private CA:
export BAO_CACERT="/path/to/openbao-ca.pem"
```

Keep TLS verification enabled. The PKI issuing/CRL URLs must be routable
(`https://openbao.example.com/v1/pki-int/ca`, `.../crl`).

### 3.1 Kubernetes auth and reviewer configuration

```bash
bao auth enable kubernetes
```

**In-cluster OpenBao** — with OpenBao's normal API-audience SA token/CA mounted,
configure the API host but **omit** a static reviewer JWT and CA value. OpenBao
re-reads its local reviewer token as it rotates:

```bash
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
```

Grant TokenReview to **OpenBao's SA only**:

```bash
kubectl create clusterrolebinding openbao-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=openbao:openbao
```

#### External OpenBao: dedicated reviewer and explicit configuration

Run provisioning with a cluster administrator and a OpenBao management session;
do not use an application token. The examples use auth mount `kubernetes`,
reviewer namespace `openbao-auth` and SA `openbao-reviewer`. The external OpenBao host
must reach the API endpoint with a hostname covered by its certificate and trust
the Kubernetes CA. A kubeconfig endpoint reachable from your laptop is not
necessarily reachable from OpenBao; do not fix that with TLS verification bypass.

Have the operator-host administrator prepare `/secure/operator` as a private
`0700` directory owned by the dedicated `openbao-reviewer-operator` account used
below. The CA/token/script paths in this example are inside that directory.

```bash
KUBE_CONTEXT=production
kubectl --context "$KUBE_CONTEXT" create namespace openbao-auth
kubectl --context "$KUBE_CONTEXT" -n openbao-auth create serviceaccount openbao-reviewer
kubectl --context "$KUBE_CONTEXT" create clusterrole external-openbao-token-reviewer \
  --verb=create --resource=tokenreviews.authentication.k8s.io
kubectl --context "$KUBE_CONTEXT" create clusterrolebinding external-openbao-token-reviewer \
  --clusterrole=external-openbao-token-reviewer \
  --serviceaccount=openbao-auth:openbao-reviewer
```

TokenReview is cluster-scoped, so this is a ClusterRole/ClusterRoleBinding, not a
namespaced Role. Only the reviewer gets it; application SAs never do. Provision
API-audience reviewer credentials into a private temporary directory:

```bash
set +x
set -euo pipefail
umask 077
private="$(mktemp -d /var/tmp/openbao-reviewer.XXXXXXXX)"
trap 'rm -rf "$private"' EXIT
KUBERNETES_HOST="$(kubectl --context "$KUBE_CONTEXT" config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.server}')"
kubectl --context "$KUBE_CONTEXT" config view --raw --minify --flatten \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode > "$private/kubernetes-ca.crt"
test -s "$private/kubernetes-ca.crt"
kubectl --context "$KUBE_CONTEXT" -n openbao-auth create token openbao-reviewer \
  --duration=1h > "$private/reviewer.jwt"
test -s "$private/reviewer.jwt"
bao write auth/kubernetes/config \
  kubernetes_host="$KUBERNETES_HOST" \
  kubernetes_ca_cert=@"$private/kubernetes-ca.crt" \
  token_reviewer_jwt=@"$private/reviewer.jwt" \
  disable_local_ca_jwt=true >/dev/null
cp "$private/kubernetes-ca.crt" /secure/operator/kubernetes-ca.crt
```

Do **not** set the reviewer's audience to `openbao`: it authenticates to the
Kubernetes API. Workload JWTs use audience `openbao` as in §3.2. `@file` keeps the
reviewer JWT out of argv/history; disable shell tracing and never log its contents.
Use your API's actual audience/lifetime policy. A TokenRequest JWT expires and
cannot be renewed through OpenBao.

The first configuration is not the end of provisioning. Replace the reviewer
before expiry using the **same config-write sequence** with a newly minted token.
OpenBao uses the replacement for future TokenReviews. Keep the previous reviewer
valid while the write is in progress; alert on a failed refresh rather than
silently waiting for auth outages. The requested one-hour duration may be capped
by Kubernetes; schedule against the actual issued lifetime.

#### Automated external reviewer replacement

Use a dedicated external operator identity, never an application identity. The
Kubernetes kubeconfig used by the automation must have its own maintained
authentication (for example, your organization's managed client certificate or
OIDC exec credentials), independent of the expiring reviewer JWT. Bind its exact
authenticated username to only the named SA's TokenRequest subresource:

```bash
kubectl --context "$KUBE_CONTEXT" -n openbao-auth create role openbao-reviewer-token-issuer \
  --verb=create --resource=serviceaccounts/token --resource-name=openbao-reviewer
kubectl --context "$KUBE_CONTEXT" -n openbao-auth create rolebinding openbao-reviewer-token-issuer \
  --role=openbao-reviewer-token-issuer --user=openbao-reviewer-updater
```

Replace `openbao-reviewer-updater` with that kubeconfig's actual authenticated
username. This identity needs neither application JWTs nor TokenReview itself.
Use a separately scoped OpenBao policy and a renewable periodic management token:

```bash
bao policy write external-kubernetes-reviewer - <<'HCL'
path "auth/kubernetes/config" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
HCL
umask 077
bao token create -orphan -period=1h -no-default-policy \
  -policy=external-kubernetes-reviewer -field=token \
  > /secure/operator/openbao-reviewer-management.token
```

The administrator performs this initial token creation. Protect the operator
directory as `0700`, token as `0600`, and do not put it in a unit file or Helm
values. This management token can update reviewer trust, so treat it as privileged
infrastructure access despite its narrow policy. An organization-managed
workload-auth session with the same policy is an alternative.

Install the following operator-owned script outside this repository as
`/secure/operator/refresh-openbao-reviewer.sh` (mode `0700`). Its environment supplies
`KUBE_CONTEXT`, the dedicated `KUBECONFIG`, `KUBERNETES_HOST`, `BAO_ADDR` and, for
private OpenBao transport TLS, `BAO_CACERT`. Persist only the public Kubernetes CA
at `/secure/operator/kubernetes-ca.crt`; it is the trusted CA obtained above:

```bash
#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
private="$(mktemp -d /var/tmp/openbao-reviewer.XXXXXXXX)"
trap 'rm -rf "$private"' EXIT
export BAO_TOKEN="$(cat /secure/operator/openbao-reviewer-management.token)"
test -n "$BAO_TOKEN"
bao token renew -self >/dev/null
kubectl --context "$KUBE_CONTEXT" -n openbao-auth create token openbao-reviewer \
  --duration=1h > "$private/reviewer.jwt"
test -s "$private/reviewer.jwt"
# Refuse an unexpectedly short-lived replacement instead of assuming one hour.
python3 - "$private/reviewer.jwt" <<'PY'
import base64, json, pathlib, sys, time
part = pathlib.Path(sys.argv[1]).read_text().strip().split(".")[1]
expiry = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))["exp"]
if expiry - time.time() < 1800:
    raise SystemExit("reviewer token lifetime is too short for this refresh schedule")
PY
bao write auth/kubernetes/config \
  kubernetes_host="$KUBERNETES_HOST" \
  kubernetes_ca_cert=@/secure/operator/kubernetes-ca.crt \
  token_reviewer_jwt=@"$private/reviewer.jwt" \
  disable_local_ca_jwt=true >/dev/null
```

Payload decoding here checks the newly API-issued token's refresh deadline; it
does not replace signature verification by Kubernetes. Run every 15 minutes, for
example with these operator-host systemd units (no secrets in the environment
file):

```ini
# openbao-kubernetes-reviewer.service
[Service]
Type=oneshot
User=openbao-reviewer-operator
UMask=0077
EnvironmentFile=/secure/operator/openbao-reviewer.env
ExecStart=/secure/operator/refresh-openbao-reviewer.sh
```

```ini
# openbao-kubernetes-reviewer.timer
[Timer]
OnCalendar=*:0/15
Persistent=true
Unit=openbao-kubernetes-reviewer.service
[Install]
WantedBy=timers.target
```

The environment file contains only nonsecret endpoints/context/credential-file
paths; provide read access to those protected files only to this operator account.
Enable/start the timer through your normal operator-host service deployment.
Alert on service failure and monitor successful refresh timestamps and both
credential expiries. The management token is renewed on each run; if automation
is down longer than its one-hour period, reauthenticate/reprovision it through an
authorized administrator. There is no permanent expiring reviewer token, no
unattended root token and no fallback that gives app SAs TokenReview.

Before the OpenBao-only charts, the isolated external-reviewer qualification used
rootless Podman HashiCorp Vault 1.20.4 outside Kind; OpenBao exposes the same
Kubernetes auth API. It used a trusted host-network-reachable Kubernetes API and protected
one-hour reviewer JWTs. Both exact app SA roles logged in before and after a
distinct reviewer replacement; wrong SA/audience and cross-role requests failed.
Reviewer TokenReview was allowed and both apps were denied. A scoped non-root
management identity updated config but could not mutate roles; an actual
scoped Kubernetes operator could mint only the reviewer token, not other/self
tokens. No JWT expiry wait, installed external scheduler, periodic-management
renewal, production network/TLS deployment or global trust modification was
claimed by that scenario. The refresh units above are the operator deployment
procedure, not an assertion they ran here.

### 3.2 Kubernetes auth roles (SA-bound, exact namespace/audience)

Bind distinct roles to the *actual rendered* ServiceAccount names and one exact
namespace. Audience must be `openbao` (the chart's default projected-token
audience; change both together). No wildcard namespaces/accounts:

```bash
bao write auth/kubernetes/role/permesi \
  bound_service_account_names="permesi" \
  bound_service_account_namespaces="permesi" \
  audience="openbao" \
  token_policies="permesi" token_type=service token_no_default_policy=true \
  token_ttl="1h" \
  token_max_ttl="4h"

bao write auth/kubernetes/role/genesis \
  bound_service_account_names="permesi-genesis" \
  bound_service_account_namespaces="permesi" \
  audience="openbao" \
  token_policies="genesis" token_type=service token_no_default_policy=true \
  token_ttl="1h" \
  token_max_ttl="4h"
```

> The ServiceAccount names are release-dependent: a release named `permesi`
> renders `permesi` (permesi chart) and `permesi-genesis` (genesis chart). Adjust
> to your `fullnameOverride`/`nameOverride`. Request renewable **service** tokens
> (TTL 1h / max TTL 4h), not nonrenewable batch tokens.

### 3.3 KV v2 seed/pepper (cryptographic identity)

These are **first-install** commands, not an automatic repair/rerun script.
Verify an existing mount's type before reuse. If config already exists, preserve
both fields; partial population requires diagnosis/restore, never regeneration.
If any application database was retained after OpenBao loss, stop and restore the
matching OpenBao identity. Only for a genuinely new deployment:

```bash
bao secrets enable -path=secret/permesi -version=2 kv
python3 -c 'import os,base64,json; print(json.dumps({k:base64.b64encode(os.urandom(32)).decode() for k in ("opaque_server_seed","mfa_recovery_pepper")}))' \
  | bao kv put -mount=secret/permesi -cas=0 config -
```

Each field is standard-base64 encoding of 32 random bytes. CAS `0` refuses to
overwrite an existing key; any failure must stop the procedure. Do not log the
JSON input, use shell tracing, or replace this with an error-to-overwrite fallback.

### 3.4 Transit mounts and keys

```bash
bao secrets enable -path=transit/permesi transit
bao secrets enable -path=transit/genesis transit

bao write -f transit/permesi/keys/totp \
  type=chacha20-poly1305 auto_rotate_period=2592000
# Operators stage, publish and activate admission signing versions explicitly.
bao write -f transit/genesis/keys/genesis-signing \
  type=ed25519 auto_rotate_period=0

# OIDC signing — only when OIDC is enabled. Separate from TOTP and admission keys.
bao write -f transit/permesi/keys/oidc-signing \
  type=rsa-2048 exportable=false allow_plaintext_backup=false \
  deletion_allowed=false auto_rotate_period=2592000
```

### 3.5 Database secrets engine

This is initial provisioning only. Supply the matching initial manager passwords
through protected mode-`0600` operator files
`/secure/operator/openbao_permesi_manager.password` and
`/secure/operator/openbao_genesis_manager.password`, not literals/argv/history.
OpenBao must trust the PostgreSQL CA for the `verify-full` connection.

```bash
bao secrets enable database
for service in permesi genesis; do
  # Genesis manages its roles through the maintenance database so credential
  # issue keeps working when its own database is saturated, and caps each lease.
  management_db="${service}"; limit=""
  if [ "${service}" = genesis ]; then management_db=postgres; limit="CONNECTION LIMIT 10 "; fi
  bao write "database/config/${service}" \
    plugin_name=postgresql-database-plugin \
    allowed_roles="${service}" \
    connection_url="postgresql://{{username}}:{{password}}@db.example.com:5432/${management_db}?sslmode=verify-full" \
    username="openbao_${service}_manager" \
    password=@"/secure/operator/openbao_${service}_manager.password" \
    max_connection_lifetime=120s \
    root_rotation_statements="ALTER ROLE \"openbao_${service}_manager\" WITH PASSWORD '{{password}}';" >/dev/null
  bao write -f "database/rotate-root/${service}" >/dev/null
  bao write "database/roles/${service}" \
    db_name="${service}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN ${limit}PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ${service}_runtime TO \"{{name}}\";" \
    renew_statements="ALTER ROLE \"{{name}}\" WITH VALID UNTIL '{{expiration}}';" \
    revocation_statements="SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.usename = '{{name}}'; REVOKE ${service}_runtime FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl=1h max_ttl=4h >/dev/null
done
```

After the first successful root rotation the bootstrap manager password is no
longer valid; remove its protected staging file through the operator credential
workflow. The steady-state password stays in OpenBao. Later operator-authorized
manager rotations are:

```bash
bao write -f database/rotate-root/permesi
bao write -f database/rotate-root/genesis
```

Reruns reuse existing manager configs and must not overwrite rotated passwords.
Check the exact `connection_details.username` and `allowed_roles` before reuse.
Initial config creation and the first manager rotation are separate operations:
a persisted config alone is not proof the rotation finished. For the manual
production procedure, interrupted provisioning requires an authorized successful
rotate-root before declaring that manager complete. The disposable helper
instead records root-only pending/completed markers in OpenBao and resumes
unfinished initial rotations using OpenBao's current credentials; normal completed
reruns leave those credentials unchanged. Neither path resets a schema owner
password or reapplies a bootstrap password to an existing manager config.
Legacy owner-as-manager installs require a reviewed manager-separated restore/
migration; the disposable helper instead accepts only explicit reset or restore.
No automatic owner-password reset is supported. Rotation scheduling is
operator-owned; no external scheduler is assumed available.

> The application always replaces DSN username/password with OpenBao-issued
> credentials from `/v1/database/creds/{permesi,genesis}`; the DSN Secret carries
> a placeholder username/password — only host/port/database and TLS options matter.

### 3.6 PKI hierarchy

```bash
bao secrets enable -path=pki-root -max-lease-ttl=315360000 pki
bao secrets enable -path=pki-int  -max-lease-ttl=94608000  pki

# Root CA generation (this command does not make the root offline)
bao write -field=certificate pki-root/root/generate/internal \
  common_name="Permesi Root CA" ttl=87600h key_type=ec key_bits=256 \
  issuer_name=permesi-root > pki-root.crt

# Intermediate: generate CSR, sign, set-signed
bao write -field=csr pki-int/intermediate/generate/internal \
  common_name="Permesi Intermediate CA" key_type=ec key_bits=256 > pki-int.csr
bao write -field=certificate pki-root/root/sign-intermediate \
  csr=@pki-int.csr common_name="Permesi Intermediate CA" ttl=26280h \
  format=pem_bundle > pki-int.crt
bao write pki-int/intermediate/set-signed certificate=@pki-int.crt

# Issuing/CRL URLs
bao write pki-root/config/urls \
  issuing_certificates="https://openbao.example.com/v1/pki-root/ca" \
  crl_distribution_points="https://openbao.example.com/v1/pki-root/crl"
bao write pki-int/config/urls \
  issuing_certificates="https://openbao.example.com/v1/pki-int/ca" \
  crl_distribution_points="https://openbao.example.com/v1/pki-int/crl"
```

The commands above keep the root in the addressed OpenBao. For a genuinely offline
production root, sign the intermediate CSR in the separately operated offline
root system and import its full signed chain into the online `pki-int` mount.

Import the complete signed issuer chain at `intermediate/set-signed`, including
each parent intermediate. The Agent writes the chain read from
`pki-int/cert/ca_chain` after the leaf; it cannot reconstruct a chain missing from
that mount. A self-signed root is included in the bundle if the mount returns it. Verify the leaf against your independently trusted root, not
against a CA accepted solely because it arrived in the bundle.

### 3.7 PKI runtime roles (service-scoped SANs)

These listener certificates are server-only: without ClientAuth (and with
`client_flag=false`) a leaked runtime key cannot be replayed against a certificate
login. `allowed_domains` lists the
exact service and public passthrough DNS names; subdomain/glob/wildcard/any-name/IP
issuance is disabled:

```bash
bao write pki-int/roles/permesi-runtime \
  allowed_domains="permesi.permesi.svc.cluster.local,api.permesi.example.com" \
  allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
  allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true \
  allow_ip_sans=false \
  key_type=ec key_bits=256 \
  key_usage="DigitalSignature,KeyAgreement" ext_key_usage="ServerAuth" \
  server_flag=true client_flag=false \
  ttl="24h" max_ttl="72h"

bao write pki-int/roles/genesis-runtime \
  allowed_domains="permesi-genesis.permesi.svc.cluster.local,genesis.permesi.example.com" \
  allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
  allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true \
  allow_ip_sans=false \
  key_type=ec key_bits=256 \
  key_usage="DigitalSignature,KeyAgreement" ext_key_usage="ServerAuth" \
  server_flag=true client_flag=false \
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
path "sys/leases/renew" {
  capabilities = ["update"]
  required_parameters = ["lease_id"]
  allowed_parameters = {
    "lease_id"  = ["database/creds/permesi/*"]
    "increment" = []
  }
}

path "database/creds/permesi"       { capabilities = ["read"] }
path "secret/permesi/data/config"   { capabilities = ["read"] }
path "secret/permesi/data/admission-authority" { capabilities = ["read"] }
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
path "sys/leases/renew" {
  capabilities = ["update"]
  required_parameters = ["lease_id"]
  allowed_parameters = {
    "lease_id"  = ["database/creds/genesis/*"]
    "increment" = []
  }
}

path "database/creds/genesis"                  { capabilities = ["read"] }
path "transit/genesis/keys/genesis-signing"    { capabilities = ["read"] }
path "transit/genesis/sign/genesis-signing" {
  capabilities = ["update"]
  required_parameters = ["input", "key_version"]
  allowed_parameters = {
    "input"       = []
    "key_version" = []
  }
}

path "pki-int/issue/genesis-runtime" { capabilities = ["create", "update"] }
path "pki-int/cert/ca_chain"         { capabilities = ["read"] }
```

Lease renewal is limited to the service's own database leases, and Genesis must
name the signing version explicitly. `pki-int/cert/ca_chain` is the
**authenticated JSON** endpoint the Agent TLS template reads for the issuer chain,
not the raw-PEM `pki-int/ca` or `pki-int/ca_chain` endpoint. Only Permesi reads
the admission authority record; nothing on the Genesis side may write it.

```bash
bao policy write permesi permesi-policy.hcl
bao policy write genesis genesis-policy.hcl
```

#### Genesis rate quotas

Genesis serves public traffic, so its OpenBao paths get separate per-source rate
buckets that leave core authority reads and administrative revocation outside
them. The module sets these for its AppRole and certificate logins; on
Kubernetes the Genesis login is its Kubernetes auth role. OpenBao stores an auth
mount path with its trailing slash, so write it that way:

```bash
quota() { bao write "sys/quotas/rate-limit/genesis-$1" path="$2" ${3:+role="$3"} rate=30 interval=1s; }
quota signing     transit/genesis/sign/genesis-signing
quota credentials database/creds/genesis
quota pki         pki-int/issue/genesis-runtime
quota kubernetes  auth/kubernetes/ genesis
```

The rate applies per source IP and per reachable OpenBao node; size it against the
shared service budget.

#### Admission authority

Permesi verifies admission tokens against the public key versions in the core
authority record `secret/permesi/data/admission-authority`. A core operator
initializes it once, outside any release, with the signing version Genesis will
use (`genesis.admissionSigningVersion`), using the application's script:

```bash
# From a checkout of the permesi repository, with a core operator token.
BAO_ADDR="https://openbao.example.com:8200" BAO_TOKEN="<operator-token>" \
  scripts/admission-authority initialize 1
```

Initialization uses check-and-set 0 and fails if the record exists. Publish and
withdraw later versions with `scripts/admission-authority publish|withdraw`; see
the [operations guide](operations.md#admission-containment-with-the-openbao-application-contract).

### 3.9 Optional: AppRole path

The Agent path is recommended. AppRole remains supported. Both services accept
either an OpenBao origin (`https://openbao.example.com:8200`) or the full login
endpoint (`.../v1/auth/approle/login`) in `openbao.url`.

```bash
bao auth enable approle
bao write auth/approle/role/permesi \
  token_policies="permesi" token_no_default_policy=true \
  token_ttl=1h token_max_ttl=4h secret_id_num_uses=1 secret_id_ttl=1h bind_secret_id=true
bao write auth/approle/role/genesis \
  token_policies="genesis" token_no_default_policy=true \
  token_ttl=1h token_max_ttl=4h secret_id_num_uses=1 secret_id_ttl=1h bind_secret_id=true
```

AppRole SecretIDs are single-use with a 1-hour TTL by default: use Agent mode for
multi-replica, restart-safe deployments, or provision SecretIDs with sufficient
uses/TTL and a rotation procedure.

### 3.10 Optional native Kubernetes authentication

Both services implement `auto`, `approle`, and `kubernetes` modes. Native auth is
not the Agent proxy and does not render PKI/TLS files.

`openbao.authMethod: auto` preserves socket→Agent and TCP→AppRole without adding
native env/JWT mounts. `approle` explicitly requires TCP. Native mode requires a
OpenBao HTTP(S) origin (optional trailing `/`, no credentials/path/query/fragment),
no managed Agent, no AppRole/wrapped/ESO OpenBao credentials, and automount false.

```yaml
openbao:
  url: https://openbao.example.com:8200
  authMethod: kubernetes
  agent:
    enabled: false
  kubernetes:
    authMount: kubernetes
    role: permesi              # genesis for the other component
    tokenPath: /var/run/secrets/openbao-native/token
    audience: openbao
    tokenExpirationSeconds: 3600
serviceAccount:
  automount: false
tls:
  existingSecret: permesi-tls  # or an operator-managed CSI/file mount
```

The role binds the exact application SA/namespace and audience as in §3.2.
`authMount` is relative (nested mounts supported), `role`/`audience` nonblank,
`tokenPath` normalized inside a dedicated non-root directory, and requested
expiration is `600..86400` seconds. The app alone gets a read-only `0400` JWT
projection; Kubernetes controls the actual issued lifetime.

The chart emits `<PREFIX>_OPENBAO_AUTH_METHOD` and
`<PREFIX>_OPENBAO_KUBERNETES_{AUTH_MOUNT,ROLE,TOKEN_PATH}` (`PERMESI` or `GENESIS`).
Known conflicting `extraEnv` entries are rejected. Generic `extraEnvFrom` remains
supported but opaque: remove legacy AppRole credential variables from imported
Secrets/ConfigMaps before native mode; the application fails closed on conflicts.
No TokenReview permission belongs on the application SA.

Authentication reads the JWT and POSTs `{role,jwt}` to
`/v1/auth/<authMount>/login`; the token must be renewable. Reauthentication is
**restart-based**: renewal failure drains/stops the process; its supervisor
restarts, reads the current JWT and reacquires token/DB credentials. No hot token
swap or fallback is implemented. Mount native OpenBao transport CA trust in the
application image/trust bundle; `openbao.agent.ca` applies only to Agent.

---

## 4. Agent values, volumes, startup gate, HTTPS

### 4.1 Values

The `openbao.agent.*` block defaults to disabled. When enabled, the chart renders
a native sidecar (container `openbao-agent`) running the pinned
`docker.io/openbao/openbao` image with Kubernetes auto-auth, a local Unix socket
proxy (`use_auto_auth_token = true`, no cache), and a PKI template that renders
the TLS bundle. Application and Agent images must be pinned by digest.

```yaml
permesi:
  serviceAccount:
    automount: false          # required in Agent mode
  openbao:
    # The app connects to this Unix socket; the Agent listens on it.
    url: unix:///var/run/permesi/openbao-agent/agent.sock
    agent:
      enabled: true
      address: https://openbao.example.com:8200   # OpenBao origin, not the socket
      image:
        repository: docker.io/openbao/openbao
        tag: "2.7.3"
        digest: "sha256:b9418c63e2185157d8ee8689a8a93265d5aadad677d6320156172bd42ad3b10b"
        pullPolicy: IfNotPresent
      auth:
        mount: kubernetes
        role: permesi
        audience: openbao
        tokenExpirationSeconds: 3600
      ca:
        existingConfigMap: openbao-ca        # public OpenBao CA; omit for public-root OpenBao
        key: ca.crt
      pki:
        mount: pki-int
        role: permesi-runtime
        commonName: permesi.permesi.svc.cluster.local
        dnsNames: [permesi.permesi.svc.cluster.local, api.permesi.example.com]
        ttl: 24h
        renewalThreshold: 0.8
```

Genesis is identical, plus the required `genesis.admissionSigningVersion`. See the
chart READMEs for the full table.

### 4.2 What the chart renders (and what it refuses)

- `tls.pemBundlePath` (`/var/run/permesi/tls/bundle.pem` by default) receives one
  atomically-replaced file: exactly one private key, the leaf, then the issuer
  chain. Directory mounts, never `subPath`. File mode `0600` (private key bundle),
  socket `0600`. The issuer chain is the one stored in `pki-int/cert/ca_chain`,
  including any returned root. Configure OpenBao with the full chain (§3.6).
- The socket and TLS bundle live in memory-backed `emptyDir` volumes —
  Agent RW, backend RO. `fsGroup` supplies the writable root; the Agent runs as the
  application's existing UID/GID (10001), nonroot, read-only root filesystem,
  `drop: ALL` capabilities, RuntimeDefault seccomp. No `hostPath`, no privileged
  chmod init, no world-writable socket.
- The projected audience-scoped JWT is mounted **only into the Agent**, not the
  backend. `use_auto_auth_token = true` — **never `"force"`** — so an explicitly
  supplied operator token is still forwarded.
- `config.socketPath` (an unrelated application-listener setting) omits the inbound
  PKI template/volume but keeps the OpenBao socket.
- Active socket/TLS destinations must be absolute files inside dedicated
  directories, never `/agent.sock` or `/bundle.pem`. Normalized
  mount directories must not overlap each other or the Agent's `/openbao/config`,
  `/var/run/secrets/openbao-token`, `/tmp`, and optional `/openbao/ca` mounts.
  `extraVolumeMounts` obey the same ancestor/descendant rule; mounting `/` is
  rejected. An inactive TLS path does not reserve a directory, but a legacy Secret
  mount still counts.
- The removed `vault:` block, `secretsProvider` and PASERK admission settings make
  rendering fail instead of being ignored.

### 4.3 Startup gate

A startup probe on the native sidecar blocks initial backend startup until a
tokenless `bao token lookup` through `-address=unix://...` succeeds and the
required bundle file is nonempty. File/socket existence alone is insufficient.
`pkiCert` may reuse a valid cached certificate after Agent restart; the probe does
not prove fresh issuance, current certificate validity, or application recovery.
The initial startup gate is not a promise to pause an already-running backend
during an independent sidecar restart.

### 4.4 Production HTTPS

- **OpenBao**: `openbao.agent.address` must be `https://`, with `openbao.agent.ca` carrying
  the public OpenBao CA. The Agent never sets `tls_skip_verify`; its Unix listener
  disables TLS only on the local socket.
- **PostgreSQL**: DSN uses `sslmode=verify-full` plus a CA mounted via
  `extraVolumes`/`extraVolumeMounts`.
- **Private keys never synchronized to Kubernetes Secrets**: backend TLS bundles
  come from Agent; no AppRole, issued DB credential or OpenBao root token is
  supplied to the app. The example still references an optional
  DSN Secret containing placeholder/connection settings, not dynamic credentials.
  Public OpenBao/PKI/DB trust anchors may be ConfigMaps.

---

## 5. Service DNS, admission trust, frontend, client, email

### 5.1 Service DNS and admission trust

- Genesis Service is `<release>-genesis.<namespace>.svc.cluster.local:8080`
  (e.g. `permesi-genesis.permesi.svc.cluster.local`); the Genesis PKI SAN must
  cover that DNS name.
- `permesi.admission.issuer`/`audience` must equal
  `GENESIS_ADMISSION_ISS`/`GENESIS_ADMISSION_AUD` on the Genesis side, or every
  admission token fails verification.
- Permesi verifies admission tokens offline against the public keys in the core
  OpenBao authority record (§3.8); it does not call Genesis, so there is no
  admission CA and no Permesi→Genesis network path.

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
  the default `outbox` mode only queues rows. Production needs a real SMTP relay.

---

## 6. Install, trusted HTTPS checks, admission smoke, edge

### 6.1 Install

```bash
helm dependency build charts/permesi-stack
helm upgrade --install permesi charts/permesi-stack \
  --namespace permesi --create-namespace --wait --timeout 900s \
  -f docs/examples/openbao-shared.yaml
```

### 6.2 Trusted HTTPS checks (never `-k`)

```bash
export CA=/path/to/your-public-pki-ca.crt
LB_IP='<your-load-balancer-ip>'

curl --cacert "$CA" --resolve "api.permesi.example.com:443:${LB_IP}" \
  https://api.permesi.example.com/live
curl --cacert "$CA" --resolve "genesis.permesi.example.com:443:${LB_IP}" \
  https://genesis.permesi.example.com/paserk.json
CLIENT_ID='<your-provisioned-production-client-uuid>'
curl --cacert "$CA" --resolve "genesis.permesi.example.com:443:${LB_IP}" \
  "https://genesis.permesi.example.com/token?client_id=${CLIENT_ID}"
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

### 6.4 Optional OpenBao-backed edge (no TLS Secrets)

Production with no TLS Secrets prefers TLS passthrough to the backend, or an
operator-provisioned edge that obtains its own TLS files from OpenBao. The existing
ingress-nginx termination example uses Kubernetes TLS Secrets and is
**legacy/alternative**, not the recommended Agent path. Web's nginx listener is
HTTP-only: an external OpenBao-backed TLS edge is still required for public HTTPS web
hosting. The Agent does **not** supply ingress/web certificates or database-server
TLS.

Keep forwarding headers untrusted when using TLS passthrough: the encrypted HTTP
headers reach Permesi unchanged, so a client could forge `X-Real-IP`. Permesi uses
the transport peer for IP attribution and throttling in this profile. To preserve
the original client address, use an L7 edge that terminates TLS, overwrites
`X-Real-IP`, and verifies TLS again upstream. Only then configure
`PERMESI_AUTH_TRUSTED_PROXIES` with that edge's narrowly scoped peer addresses.

---

## 7. Day-2: rotation, recovery, schema upgrades, rollback limits

### 7.1 Leaf certificate reissue/reload vs CA rollout

- **Leaf reissue**: the Agent reissues the TLS bundle before TTL expiry
  (`renewalThreshold` default `0.8`); the app watches the bundle mtime every ~10 s
  and reloads without a pod restart. Do not switch the bundle to `subPath`.
- **CA/intermediate rotation** requires a **rollout**: roll with overlapping
  trusted roots before an issuer change, then restart pods so clients and bundles
  pick up the new chain.

### 7.2 Agent restart and JWT rotation

- The Agent re-reads rotated service-account JWTs. Its probe checks authenticated
  proxy access and required file presence, not new certificate issuance; a valid
  cached bundle can be reused. Verify socket recovery and backend requests after
  an independent Agent restart. M-QS reports Agent-only restart recovery; natural
  projected-JWT expiry/rotation remains a separate qualification.
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

Permesi, Genesis and OpenBao Agent image blocks require `digest:
sha256:<64 lowercase hex>`; rendering fails without one (the web image may still
fall back to `repository:tag`). The digest renders `repository@digest` and
overrides the tag, so replace tag and digest together. App-release automation
updates the managed app digests and leaves Agent pins unchanged.
See [release procedures](operations.md#10-release-and-image-identity).

Signing/provenance are independent of digest selection. The application workflow
contains keyless signing/OCI-attestation steps, but local chart validation is not
remote signing evidence and older pins are not thereby claimed signed.
For a release, verify its actual digest with exact workflow identity and commit,
never a permissive identity regex. The release workflow runs on `develop`:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "https://github.com/permesi/permesi/.github/workflows/release.yml@refs/heads/develop" \
  --certificate-github-workflow-sha "${RELEASE_COMMIT}" \
  "ghcr.io/permesi/${SERVICE}@${DIGEST}"
```

Obtain the commit and digest from trusted release metadata (the release notes and the
dispatch payload). Validate OCI provenance
against the same subject digest and expected source/workflow using GitHub's
attestation verifier. This guide did not execute remote Cosign/GitHub verification.

### 8.2 Restricted diagnostics

Never print or commit secrets, tokens, JWTs, private keys, or PEM key contents.
Sanitize diagnostics: describe status codes, certificate subject/serial, and
rollout state, not credentials. Use `kubectl describe`/`events` with redaction.

### 8.3 Scoped teardown

For the script quickstart in a namespace you created exclusively for this install:

```bash
CTX=kind-permesi-helm-test
NS=permesi-quickstart
R=permesi
helm --kube-context "$CTX" uninstall "$R-web" "$R" "$R-genesis" "$R-quickstart" -n "$NS"
kubectl --context "$CTX" delete namespace "$NS"
```

Uninstall the helper **before** deleting the namespace so its Helm-owned
cluster-scoped reviewer binding is removed. With pregrant mode, the administrator
must separately delete the operator-owned Role/Binding using the exact commands
in [the pregrant procedure](#namespaced-installer-with-pregranted-reviewer).
The retained bootstrap Secret is removed by namespace deletion. Stop
`connect.sh` first. Inspect any failed uninstall before deleting;
do not hide errors. Delete a Kind cluster only if you created it solely for this
run; never delete shared namespaces/clusters or external production dependencies.

### 8.4 Dev state-loss warning

The disposable quickstart runs dev-mode OpenBao **in memory**: OpenBao loss with a
retained PostgreSQL loses cryptographic identity (OPAQUE seed, transit keys, PKI),
not merely configuration. A fresh bootstrap cannot manufacture replacement keys
and call the old database recovered. This profile is explicitly not
production-safe.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Chart render fails in Agent mode on an old cluster | `openbao.agent.enabled=true` needs Kubernetes ≥ 1.29 with `SidecarContainers`; disable Agent or upgrade the cluster |
| Pod stuck `PodInitializing`, Agent startup probe failing | OpenBao unreachable, wrong `openbao.agent.address`/CA, Kubernetes role/SA/namespace/audience mismatch, or PKI role denies the CN/SAN; check Agent logs (no secrets) and `bao token lookup` from the Agent |
| Backend crash-loops with DB auth failure | DSN placeholder username/password or DB role misconfigured; check `/v1/database/creds/{permesi,genesis}` issuance from OpenBao |
| Admission tokens rejected | `admission.issuer`/`audience` vs `GENESIS_ADMISSION_ISS`/`AUD` mismatch, or `genesis.admissionSigningVersion` not published (or withdrawn) in the core admission authority |
| Leaf cert not reloading | Bundle mounted via `subPath` (pins old file); use directory mount |
| `check.sql` fails | pg_cron not installed or scheduled jobs not registered |
| AppRole login 404 | `openbao.url` names a path that is not the AppRole login (use the origin or `/v1/auth/approle/login`), or the AppRole mount differs |
| Chart render fails with "renamed to openbao" or "secretsProvider was removed" | Values written for chart 0.5: rename `vault:` to `openbao:`, drop `secretsProvider` and the PASERK admission settings |
