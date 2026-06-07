#!/usr/bin/env bash
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require VAULT_ADDR
require VAULT_TOKEN

keycloak_namespace="${KEYCLOAK_NAMESPACE:-keycloak}"
keycloak_name="${KEYCLOAK_NAME:-openclaw-keycloak}"
keycloak_realm="${KEYCLOAK_REALM:-agentic}"
keycloak_client_id="${KEYCLOAK_CLIENT_ID:-vault}"
keycloak_group="${KEYCLOAK_GROUP:-vault-users}"
vault_kv_mount="${VAULT_KV_MOUNT:-users}"
vault_oidc_mount="${VAULT_OIDC_MOUNT:-oidc}"
vault_oidc_role="${VAULT_OIDC_ROLE:-default}"

keycloak_host="${KEYCLOAK_HOST:-$(oc get route -n "${keycloak_namespace}" "${keycloak_name}" -o jsonpath='{.spec.host}')}"
vault_host="${VAULT_HOST:-${VAULT_ADDR#https://}}"

client_secret="${KEYCLOAK_VAULT_CLIENT_SECRET:-}"
if [[ -z "${client_secret}" ]]; then
  client_secret="$(oc get secret vault-oidc-client -n "${keycloak_namespace}" -o jsonpath='{.data.clientSecret}' | base64 -d)"
fi

enable_auth() {
  local mount="$1"
  local type="$2"
  if ! vault auth list -format=json | jq -e --arg mount "${mount}/" 'has($mount)' >/dev/null; then
    vault auth enable -path="${mount}" "${type}"
  fi
}

enable_secrets() {
  local mount="$1"
  if ! vault secrets list -format=json | jq -e --arg mount "${mount}/" 'has($mount)' >/dev/null; then
    vault secrets enable -path="${mount}" kv-v2
  fi
}

enable_auth "${vault_oidc_mount}" oidc
enable_auth kubernetes kubernetes
enable_secrets "${vault_kv_mount}"

vault write "auth/${vault_oidc_mount}/config" \
  oidc_discovery_url="https://${keycloak_host}/realms/${keycloak_realm}" \
  oidc_client_id="${keycloak_client_id}" \
  oidc_client_secret="${client_secret}" \
  default_role="${vault_oidc_role}"

oidc_accessor="$(vault auth list -format=json | jq -r --arg mount "${vault_oidc_mount}/" '.[$mount].accessor')"

vault write identity/group \
  name="${keycloak_group}" \
  type=external \
  policies=vault-user-sandbox >/dev/null

group_id="$(vault read -field=id "identity/group/name/${keycloak_group}")"
alias_id="$(
  for id in $(vault list -format=json identity/group-alias/id 2>/dev/null | jq -r '.[]?' || true); do
    vault read -format=json "identity/group-alias/id/${id}"
  done | jq -r --arg name "${keycloak_group}" --arg mount_accessor "${oidc_accessor}" '
    select(.data.name == $name and .data.mount_accessor == $mount_accessor) |
    .data.id
  ' | head -n 1
)"

if [[ -z "${alias_id}" ]]; then
  vault write identity/group-alias \
    name="${keycloak_group}" \
    mount_accessor="${oidc_accessor}" \
    canonical_id="${group_id}" >/dev/null
fi

vault write "auth/${vault_oidc_mount}/role/${vault_oidc_role}" - <<EOF
{
  "bound_audiences": "${keycloak_client_id}",
  "allowed_redirect_uris": [
    "http://localhost:8250/oidc/callback",
    "https://${vault_host}/ui/vault/auth/${vault_oidc_mount}/oidc/callback"
  ],
  "oidc_scopes": [],
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "bound_claims": {
    "groups": ["${keycloak_group}"]
  },
  "token_policies": "default"
}
EOF

vault policy write vault-user-sandbox - <<EOF
path "sys/internal/ui/mounts/${vault_kv_mount}" {
  capabilities = ["read"]
}

path "${vault_kv_mount}/data/{{identity.entity.aliases.${oidc_accessor}.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "${vault_kv_mount}/metadata/{{identity.entity.aliases.${oidc_accessor}.name}}" {
  capabilities = ["list", "read"]
}

path "${vault_kv_mount}/metadata/{{identity.entity.aliases.${oidc_accessor}.name}}/*" {
  capabilities = ["list", "read", "delete"]
}

path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/config \
  kubernetes_host="$(oc whoami --show-server)"

cat <<EOF
Vault configured.

Human login:
  vault login -method=oidc path=${vault_oidc_mount} role=${vault_oidc_role}

Workload Kubernetes auth mount:
  kubernetes

Next, create tenant workload policies with:
  scripts/vault/create-tenant.sh <tenant> <vault-role> <claw-namespace> <claw-service-account>
EOF
