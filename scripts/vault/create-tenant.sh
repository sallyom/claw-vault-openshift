#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "Usage: $0 <tenant> <vault-role> <claw-namespace> <claw-service-account>" >&2
  exit 1
fi

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require VAULT_ADDR
require VAULT_TOKEN

tenant="$1"
role="$2"
claw_namespace="$3"
service_account="$4"

vault_kv_mount="${VAULT_KV_MOUNT:-users}"
workload_policy="openclaw-${tenant}-read"

vault policy write "${workload_policy}" - <<EOF
path "${vault_kv_mount}/data/${tenant}/*" {
  capabilities = ["read"]
}

path "${vault_kv_mount}/metadata/${tenant}/*" {
  capabilities = ["read", "list"]
}
EOF

vault write "auth/kubernetes/role/${role}" \
  bound_service_account_names="${service_account}" \
  bound_service_account_namespaces="${claw_namespace}" \
  policies="${workload_policy}" \
  ttl=24h

cat <<EOF
Created Vault workload role ${role}.

Bound service account:
  ${claw_namespace}/${service_account}

Allowed secret prefix:
  ${vault_kv_mount}/data/${tenant}/*
EOF
