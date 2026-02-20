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

## ConfigMap strategies

- Default: chart creates a ConfigMap with `config.js` data.
- External: set `runtimeConfig.existingConfigMap` to reuse an existing ConfigMap.

When using an external ConfigMap, ensure the key specified by `runtimeConfig.key`
exists and contains valid JavaScript that defines `window.PERMESI_CONFIG`.

## Example

```yaml
web:
  runtimeConfig:
    apiBaseUrl: https://api.permesi.example.com
    tokenBaseUrl: https://genesis.permesi.example.com
    clientId: 00000000-0000-0000-0000-000000000000
    opaqueServerId: api.permesi.example.com
```
