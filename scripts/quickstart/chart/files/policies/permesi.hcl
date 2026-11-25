# Common workload token lifecycle.
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "sys/leases/renew" {
  capabilities = ["update"]
  required_parameters = ["lease_id"]
  allowed_parameters = {
    "lease_id" = ["database/creds/permesi/*"]
    "increment" = []
  }
}

# Permesi runtime: DB credentials, config seed/pepper, TOTP envelope keys.
path "database/creds/permesi"                  { capabilities = ["read"] }
path "secret/permesi/data/config"              { capabilities = ["read"] }
path "transit/permesi/datakey/plaintext/totp"  { capabilities = ["update"] }
path "transit/permesi/decrypt/totp"            { capabilities = ["update"] }

path "secret/permesi/data/admission-authority" { capabilities = ["read"] }
