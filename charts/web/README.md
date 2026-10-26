# web chart

Production-oriented Helm chart for the Permesi web UI.

## Runtime config.js handling

The application loads `/config.js` and reads `window.PERMESI_CONFIG` at runtime.
This chart mounts that file from a ConfigMap so you can change endpoints and
client ID per environment without rebuilding the image.

Managed values:

- `runtimeConfig.apiBaseUrl` -> `api_base_url`
- `runtimeConfig.tokenBaseUrl` -> `token_base_url`
- `runtimeConfig.clientId` -> `client_id`
- `runtimeConfig.opaqueServerId` -> `opaque_server_id`

All of these are public frontend values. Do not store secrets in `config.js`.

## Required runtime configuration

When the chart manages the ConfigMap (the default), all four runtime values
are **required** and must be non-blank. A blank or missing value fails
rendering/installation rather than silently falling back to the image-baked
endpoints.

These are **browser-side URLs and identifiers**, not cluster-local DNS names.
The browser — not nginx — makes these requests, so they must be reachable from
the user's machine:

- `apiBaseUrl`: the public HTTPS origin of the Permesi API.
- `tokenBaseUrl`: the public HTTPS origin of Genesis.
- `clientId`: a provisioned Genesis client ID.
- `opaqueServerId`: the backend OPAQUE server ID; it must match the backend.

Do not set these to in-cluster Service names such as
`http://permesi.permesi.svc.cluster.local`: the browser cannot resolve them.

### Upgrade note: allowBuildDefaults

Older releases defaulted all four keys to empty and relied on the image's
baked endpoints. That behavior is no longer the default. If you are upgrading
and cannot yet supply real endpoints, set:

```yaml
runtimeConfig:
  allowBuildDefaults: true
```

This escape hatch restores the old fallback-to-image-baked-endpoints behavior
and is **not recommended for production**, since it may silently contact the
wrong environment. Prefer setting the four real values.

### extraEnv cannot reconfigure the WASM

Setting `PERMESI_API_BASE_URL` or similar via `extraEnv`/`extraEnvFrom` does
not configure the client: those variables are read at WASM build time, not by
the served nginx container. Use `runtimeConfig.*` instead.

## ConfigMap strategies

- Default: chart creates a ConfigMap with `config.js` data and adds a
  `checksum/runtime-config` pod annotation so runtime-only upgrades roll the
  Deployment.
- External: set `runtimeConfig.existingConfigMap` to reuse an existing
  ConfigMap.

When using an external ConfigMap:

- Ensure the key specified by `runtimeConfig.key` exists and contains valid
  JavaScript that defines `window.PERMESI_CONFIG`.
- You own validating the values; the nonblank validation is skipped.
- The chart cannot hash data it does not own, so no checksum annotation is
  added. After changing the external ConfigMap, roll pods explicitly, e.g.:

  ```sh
  kubectl rollout restart deployment/<release>-web
  ```

## Image digest precedence

Set `image.digest` (`sha256:<64 hex>`) to pin by digest: the chart renders
`repository@digest` and a tag change does not override it. Clear the digest to
return to `repository:tag`. Digests must match `sha256:[0-9a-f]{64}`; a digest
does not by itself establish signature or provenance verification.

## Example

```yaml
web:
  runtimeConfig:
    apiBaseUrl: https://api.permesi.example.com
    tokenBaseUrl: https://genesis.permesi.example.com
    clientId: 00000000-0000-0000-0000-000000000000
    opaqueServerId: api.permesi.example.com
```
