# permesi chart

Production-oriented Helm chart for the permesi IAM service.

## What it exposes

This chart maps runtime configuration to the same environment variables used by
`permesi --help`, including:

- server mode (`PERMESI_PORT` or `PERMESI_SOCKET_PATH`)
- DB and TLS inputs (`PERMESI_DSN`, `PERMESI_TLS_PEM_BUNDLE`)
- admission verifier settings (`PERMESI_ADMISSION_*`)
- Vault auth and KV paths (`PERMESI_VAULT_*`)
- auth/session/outbox/OPAQUE/admin settings

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
permesi:
  replicaCount: 2
  database:
    dsn:
      existingSecret: permesi-db
      secretKey: dsn
  tls:
    existingSecret: permesi-tls
    secretKey: bundle.pem
  admission:
    paserkUrl: https://genesis.permesi.svc.cluster.local:8080/paserk.json
  vault:
    url: https://vault.example.com:8200
    roleId:
      existingSecret: permesi-vault
      secretKey: role_id
    secretId:
      existingSecret: permesi-vault
      secretKey: secret_id
```

## Validation rules

The chart enforces these invariants at render time:

- `service.enabled` must be `false` when `config.socketPath` is set.
- `vault.secretId` and `vault.wrappedToken` are mutually exclusive.
- When `vault.url` is HTTP(S), `vault.roleId` and one of `vault.secretId` or
  `vault.wrappedToken` must be configured.
