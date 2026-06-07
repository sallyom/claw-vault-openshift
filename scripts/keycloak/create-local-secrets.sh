#!/usr/bin/env bash
set -euo pipefail

namespace="${KEYCLOAK_NAMESPACE:-keycloak}"
admin_user="${KEYCLOAK_ADMIN_USER:-admin}"

admin_password="${KEYCLOAK_ADMIN_PASSWORD:-$(openssl rand -base64 30)}"
db_password="${KEYCLOAK_DB_PASSWORD:-$(openssl rand -base64 30)}"
vault_client_secret="${KEYCLOAK_VAULT_CLIENT_SECRET:-$(openssl rand -base64 30)}"

oc create secret generic keycloak-bootstrap-admin \
  -n "${namespace}" \
  --from-literal=username="${admin_user}" \
  --from-literal=password="${admin_password}" \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic keycloak-db \
  -n "${namespace}" \
  --from-literal=username=keycloak \
  --from-literal=password="${db_password}" \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic vault-oidc-client \
  -n "${namespace}" \
  --from-literal=clientSecret="${vault_client_secret}" \
  --dry-run=client -o yaml | oc apply -f -

cat <<EOF
Created or updated Keycloak bootstrap secrets in namespace ${namespace}.

Keycloak admin username: ${admin_user}
Keycloak admin password: ${admin_password}
Vault OIDC client secret: ${vault_client_secret}

Save these values in a secure password manager. They are not written to git.
EOF

