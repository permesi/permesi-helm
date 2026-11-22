# Genesis listener certificate (Agent pkiCert).
path "pki-int/issue/genesis-runtime" { capabilities = ["create", "update"] }
path "pki-int/cert/ca_chain" { capabilities = ["read"] }
