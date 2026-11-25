# Permesi listener certificate (Agent pkiCert) and its public CA chain.
path "pki-int/issue/permesi-runtime" { capabilities = ["create", "update"] }
path "pki-int/cert/ca_chain"         { capabilities = ["read"] }
