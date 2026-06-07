# Onboard a User

This runbook is for the Vault, Keycloak, and OpenShift admin who prepares one
new user for OpenClaw Vault-backed provider secrets.

The examples use:

- Keycloak username: `alice`
- OpenShift namespace: `alice-claw`
- Claw name and service account: `claw`
- Vault mount: `users`
- Vault prefix: `alice`
- Vault workload role: `alice-openclaw`

Keep the Vault prefix aligned with the Keycloak username for individual
self-service users. The shared human Vault policy lets each Keycloak user
manage only their own prefix under the `users` mount.

## 1. Add the Keycloak User

Log into the Keycloak admin console with the bootstrap admin user.

```sh
oc get route -n keycloak openclaw-keycloak
oc get secret keycloak-bootstrap-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d; echo
oc get secret keycloak-bootstrap-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d; echo
```

In the `agentic` realm:

1. Create or import user `alice`.
2. Set an initial password. Use a temporary password if the user should change
   it on first login.
3. Add `alice` to the `vault-users` group.

## 2. Create the Vault Tenant

Run from this repository with a Vault admin token.

```sh
export VAULT_ADDR=https://vault.apps.example.com
export VAULT_TOKEN="$(jq -r '.root_token' vault-unseal.json)"

scripts/vault/create-tenant.sh alice alice-openclaw alice-claw claw
```

This creates or updates:

- Shared KV v2 mount: `users/`
- Workload policy: `openclaw-alice-read`
- Workload role: `alice-openclaw`
- Kubernetes auth role binding: `alice-claw/claw`

The human write policy is global and templated by Keycloak username, so no
separate human Vault policy assignment is needed for the `users/alice/*`
prefix.

## 3. Prepare OpenShift

Create or let the non-admin user create the target namespace, depending on your
cluster policy.

```sh
oc new-project alice-claw
```

The OpenClaw operator creates the service account named after the Claw. For this
example, the Claw must be named `claw` so the Vault Kubernetes auth role
matches the proxy pod service account:

```text
alice-claw/claw
```

If the Claw name changes, rerun `create-tenant.sh` with the new service account
name.

## 4. Configure the Claw

The Claw should use the shared `users` mount and workload role created above.

```yaml
spec:
  vault:
    authRole: alice-openclaw
    kvMount: users
    kvVersion: 2
  credentials:
    - name: openrouter
      provider: openrouter
      vaultRef:
        - id: alice/openrouter/apiKey
```

Users only configure `vaultRef` entries for providers they actually use.

## 5. User Secret Path

After the user logs into Vault through OIDC, they open the `users` secrets
engine and create provider secrets under their username prefix:

```text
alice/openrouter
alice/openai
alice/anthropic
alice/google
alice/vertex
```

Example fields:

```sh
vault kv put users/alice/openrouter apiKey="<openrouter-api-key>"
vault kv put users/alice/openai apiKey="<openai-api-key>"
vault kv put users/alice/anthropic apiKey="<anthropic-api-key>"
vault kv put users/alice/google apiKey="<google-api-key>"
vault kv put users/alice/vertex credentialsJson=@gcp-credentials.json
```

In the Vault UI, the user selects the `users` secrets engine and enters their
full user-prefixed secret path, such as `alice/openrouter`.

## 6. Verify

Check the shared mount and workload role:

```sh
vault secrets list | grep '^users/'
vault auth list | grep '^kubernetes/'
vault read auth/kubernetes/role/alice-openclaw
vault policy read openclaw-alice-read
```

Check the reconciled proxy deployment:

```sh
oc get deployment -n alice-claw claw-proxy -o yaml
```

Expected details:

- `serviceAccountName: claw`
- Vault Agent init and sidecar containers
- `vault.hashicorp.com/auth-type: kubernetes`
- `vault.hashicorp.com/auth-path: auth/kubernetes`
- `vault.hashicorp.com/role: alice-openclaw`

Check Vault Agent init if the proxy pod does not become ready:

```sh
oc logs -n alice-claw deployment/claw-proxy -c vault-agent-init
```
