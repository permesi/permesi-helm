# OIDC signing (only when OIDC mode is enabled). No rotate/export/config/delete.
path "transit/permesi/keys/oidc-signing" { capabilities = ["read"] }
path "transit/permesi/sign/oidc-signing" { capabilities = ["update"] }
