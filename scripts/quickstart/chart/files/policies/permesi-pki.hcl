# Permesi listener certificate (Agent pkiCert) and public CA chain (PASERK CA).
path "pki-int/issue/permesi-runtime" { capabilities = ["create", "update"] }
path "pki-int/cert/ca_chain"         { capabilities = ["read"] }
