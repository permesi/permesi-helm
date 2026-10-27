# TODO

This tracks the current release preparation. Installation and qualification
procedures remain in the [guide](docs/install-guide.md#qualifying-candidate-application-images)
and [release runbook](docs/operations.md#10-release-and-image-identity).
The [application readiness record](https://github.com/permesi/permesi/blob/sandbox/docs/release-readiness.md)
tracks the shared dependency blocker and application follow-ups.

- [x] Align all four product chart versions and umbrella component dependencies at 0.4.6 while preserving application 0.4.3 defaults.
- [x] Validate chart alignment and matching immutable images, application revision and SQL archive pins in CI and publication workflows. Release updates refresh these pins together; tag-only updates remain drafts.
- [x] Pass [Charts CI](https://github.com/permesi/permesi-helm/actions/runs/40477040602) at implementation commit `f031e2424553b6e5ea2dfde8dd152feb1613bb8b`, including 319 chart tests and the real packaged embedded stack in Kind.
- [x] Qualify application sandbox `ef3f9e2e13a8aaf24be04462c4a5099d139d65ea` locally with matching SQL and actual image manifests: packaged install/reinstall, Vault auth transitions and full browser upgrade/passkey persistence pass. Legacy nonresident credentials remain preserved and require new enrollment.
- [ ] Keep `sandbox/release-readiness` unmerged while publication is paused. Application Rust audit still fails on `crypto-bigint 0.5.5` / `RUSTSEC-2026-0387`; review compatible upstream releases around 2026-11-03, not an automatic release date.
- [ ] Once the application dependency audit passes, qualify the final application images and matching SQL again, require current application/Helm CI, and obtain publication authorization before promotion. Successful Helm `main` CI can automatically release charts.
- [ ] Complete the separate [production and external qualifications](docs/operations.md#11-quickstart-qualification-and-known-boundaries) before claiming production readiness; disposable Kind coverage does not establish production durability or HA.
