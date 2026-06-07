#!/usr/bin/env bash
set -euo pipefail

namespace="${VAULT_NAMESPACE:-vault}"
pod="${VAULT_POD:-vault-0}"
output="${VAULT_UNSEAL_FILE:-vault-unseal.json}"

if [[ -e "${output}" ]]; then
  echo "${output} already exists; refusing to overwrite unseal material." >&2
  exit 1
fi

oc rsh -n "${namespace}" "${pod}" vault operator init -format=json >"${output}"

for index in 0 1 2; do
  key="$(jq --argjson i "${index}" -r '.unseal_keys_b64[$i]' "${output}")"
  oc rsh -n "${namespace}" "${pod}" vault operator unseal "${key}"
done

cat <<EOF
Vault initialized and unsealed.

Unseal material was written to ${output}.
Store that file securely and remove it from this working tree when done.
EOF
