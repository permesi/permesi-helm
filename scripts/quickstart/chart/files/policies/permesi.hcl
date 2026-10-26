# Common workload token lifecycle.
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "sys/leases/renew"       { capabilities = ["update"] }

# Permesi runtime: DB credentials, config seed/pepper, TOTP envelope keys.
path "database/creds/permesi"                  { capabilities = ["read"] }
path "secret/permesi/data/config"              { capabilities = ["read"] }
path "transit/permesi/datakey/plaintext/totp"  { capabilities = ["update"] }
path "transit/permesi/decrypt/totp"            { capabilities = ["update"] }
