# Common workload token lifecycle.
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "sys/leases/renew"       { capabilities = ["update"] }

# Genesis runtime: DB credentials and admission-token signing.
path "database/creds/genesis"                { capabilities = ["read"] }
path "transit/genesis/keys/genesis-signing"  { capabilities = ["read"] }
path "transit/genesis/sign/genesis-signing"  { capabilities = ["update"] }
