# permesi-stack chart

Umbrella chart that installs platform components via subcharts:

- `permesi`
- `genesis`
- `web`

Each component can be enabled/disabled with:

- `permesi.enabled`
- `genesis.enabled`
- `web.enabled`

To configure runtime behavior, set nested values under each component key.

Example:

```yaml
permesi:
  database:
    dsn:
      existingSecret: permesi-db
      secretKey: dsn

genesis:
  database:
    dsn:
      existingSecret: genesis-db
      secretKey: dsn

web:
  runtimeConfig:
    apiBaseUrl: https://api.permesi.example.com
    tokenBaseUrl: https://genesis.permesi.example.com
    clientId: 00000000-0000-0000-0000-000000000000
    opaqueServerId: api.permesi.example.com
```
