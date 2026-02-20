# genesis chart

Production-oriented Helm chart for the genesis edge admission service.

## What it exposes

This chart maps runtime configuration to the same environment variables used by
`genesis --help`, including:

- server mode (`GENESIS_PORT` or `GENESIS_SOCKET_PATH`)
- DB and TLS inputs (`GENESIS_DSN`, `GENESIS_TLS_PEM_BUNDLE`)
- Vault auth settings (`GENESIS_VAULT_*`)

## Secret handling

For sensitive fields you can use either:

- inline value (`*.value`) for local/dev
- Kubernetes Secret reference (`*.existingSecret` + `*.secretKey`) for production

This applies to:

- `database.dsn`
- `vault.roleId`
- `vault.secretId`
- `vault.wrappedToken`

## Example (stack-style override)

```yaml
genesis:
  replicaCount: 2
  database:
    dsn:
      existingSecret: genesis-db
      secretKey: dsn
  tls:
    existingSecret: genesis-tls
    secretKey: bundle.pem
  vault:
    url: https://vault.example.com:8200
    roleId:
      existingSecret: genesis-vault
      secretKey: role_id
    secretId:
      existingSecret: genesis-vault
      secretKey: secret_id
```

## Validation rules

The chart enforces these invariants at render time:

- `service.enabled` must be `false` when `config.socketPath` is set.
- `vault.secretId` and `vault.wrappedToken` are mutually exclusive.
- When `vault.url` is HTTP(S), `vault.roleId` and one of `vault.secretId` or
  `vault.wrappedToken` must be configured.
