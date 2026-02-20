# permesi-stack chart

Umbrella chart that installs the platform components via subcharts:

- `permesi`
- `genesis`
- `web`

Each subchart can be enabled/disabled with:

- `permesi.enabled`
- `genesis.enabled`
- `web.enabled`

To configure runtime behavior, set values under each component key and they will
be passed directly to the corresponding subchart.

Example:

```yaml
permesi:
  replicaCount: 2
  database:
    dsn:
      existingSecret: permesi-db
      secretKey: dsn

genesis:
  replicaCount: 2
  database:
    dsn:
      existingSecret: genesis-db
      secretKey: dsn
```
