# Setup Runbook

This runbook installs Vault and Keycloak for OpenClaw secret management on a
test OpenShift cluster.

Keycloak is only for human Vault UI/CLI access. OpenClaw workload access uses
Vault Agent with Kubernetes service account auth.

## 1. Confirm Operators

The Red Hat build of Keycloak Operator should be installed in the `keycloak`
namespace:

```sh
oc get subscription,csv,pods -n keycloak
```

The OpenClaw operator must include Vault Agent injector support:

```sh
oc get deployment -n claw-operator claw-operator-controller-manager
```

If the Keycloak operator is not installed yet:

```sh
oc apply -f manifests/keycloak/operator.yaml
oc wait -n keycloak --for=jsonpath='{.status.phase}'=Succeeded \
  csv/rhbk-operator.v26.6.2-opr.1 --timeout=10m
```

## 2. Prepare Local Environment

```sh
cp env.example .env
```

Edit `.env` for the cluster:

- `VAULT_ADDR`
- `KEYCLOAK_NAMESPACE`
- `KEYCLOAK_NAME`
- `KEYCLOAK_REALM`

Load it:

```sh
set -a
. ./.env
set +a
```

## 3. Create Keycloak Secrets

Generate local bootstrap secrets. The command prints generated passwords once.
Store them in a password manager.

```sh
scripts/keycloak/create-local-secrets.sh
```

## 4. Deploy Keycloak

```sh
oc apply -k manifests/keycloak
```

Wait for readiness:

```sh
oc wait -n keycloak --for=condition=Ready keycloak/openclaw-keycloak --timeout=15m
oc get route -n keycloak openclaw-keycloak
```

## 5. Deploy Vault

```sh
helm upgrade -i -n vault vault hashicorp/vault \
  -f manifests/vault/values-vault-openshift.yaml \
  --create-namespace \
  --set server.route.host=vault.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
```

Wait for the server pod to start. It will not become Ready until Vault is
initialized and unsealed.

```sh
oc wait -n vault --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=10m
```

## 6. Initialize and Unseal Vault

```sh
scripts/vault/init-unseal.sh
```

The script writes `vault-unseal.json`, which is ignored by git. Store it
securely and remove local copies when you are done.

Export the root token for bootstrap commands:

```sh
export VAULT_TOKEN="$(jq -r '.root_token' vault-unseal.json)"
export VAULT_ADDR="https://$(oc get route -n vault vault -o jsonpath='{.spec.host}')"
```

## 7. Import the Keycloak Realm

Update `manifests/keycloak/realm-import.yaml` before applying:

- Replace `https://vault.apps.example.com` with `VAULT_ADDR`.

Then import the realm:

```sh
oc apply -f manifests/keycloak/realm-import.yaml
oc get keycloakrealmimport -n keycloak agentic -o yaml
```

## 8. Configure Vault

```sh
scripts/vault/configure-vault.sh
```

This enables:

- OIDC auth for human login through Keycloak.
- KV v2 secrets at `users/`.
- A per-user Vault policy based on the OIDC username.
- Kubernetes auth for OpenClaw proxy workloads.

## 9. Add a Keycloak User

Log into the Keycloak admin console with the bootstrap admin user:

```sh
oc get route -n keycloak openclaw-keycloak
oc get secret keycloak-bootstrap-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d; echo
oc get secret keycloak-bootstrap-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d; echo
```

In the `agentic` realm:

- Create or import the user.
- Set an initial password. Use a temporary password if the user should change
  it on first login.
- Add the user to the `vault-users` group.

The imported Vault client relies on the `groups` client scope. That scope must
include both the `groups` mapper and the `preferred_username` mapper so Vault
can bind group membership and name the user's entity.

## 10. Create a Tenant

The OpenClaw operator creates a service account with the same name as the Claw.
For a Claw named `instance` in namespace `team-a-claw`, create:

```sh
scripts/vault/create-tenant.sh team-a team-a-openclaw team-a-claw instance
```

This grants the service account read-only access to:

```text
users/data/team-a/*
```

Verify the workload auth mount, role, and policy:

```sh
vault auth list | grep '^kubernetes/'
vault read auth/kubernetes/role/team-a-openclaw
vault policy read openclaw-team-a-read
```

## 11. User Secret Management

After the Keycloak user is added to the `vault-users` group, they can log into
Vault:

```sh
vault login -method=oidc path=oidc role=default
```

Then they can write whichever provider secrets they use:

```sh
vault kv put users/team-a/openrouter apiKey="<provider-api-key>"
vault kv put users/team-a/openai apiKey="<provider-api-key>"
vault kv put users/team-a/anthropic apiKey="<provider-api-key>"
vault kv put users/team-a/google apiKey="<provider-api-key>"
vault kv put users/team-a/vertex credentialsJson=@gcp-credentials.json
```

## 12. Configure a Claw

Patch or create a Claw with `spec.vault` and only the
`credentials[].vaultRef` entries that tenant uses:

```yaml
spec:
  vault:
    authRole: team-a-openclaw
    kvMount: users
    kvVersion: 2
  credentials:
    - name: openrouter
      provider: openrouter
      vaultRef:
        - id: team-a/openrouter/apiKey
```

Vault Agent reads `users/data/team-a/openrouter` and renders the `apiKey`
field into a file that the proxy uses for outbound provider calls.

OpenRouter, OpenAI, Anthropic, direct Google/Gemini API-key credentials, and
GCP credential JSON for Google Vertex Anthropic can all use `vaultRef` with the
Vault Agent flow. They do not all need to be present on every Claw. If a
configured `vaultRef` does not exist in Vault, the injected Vault Agent init
container fails until the secret is written.

## 13. Verify

Check the reconciled proxy deployment:

```sh
oc get deployment -n team-a-claw instance-proxy -o yaml
```

Expected Vault Agent auth details:

- `serviceAccountName: instance`
- Vault Agent init and sidecar containers
- `vault.hashicorp.com/auth-type: kubernetes`
- `vault.hashicorp.com/auth-path: auth/kubernetes`
- `vault.hashicorp.com/role: team-a-openclaw`

Check the rollout and Vault Agent init logs:

```sh
oc rollout status deployment/instance-proxy -n team-a-claw
oc logs -n team-a-claw deployment/instance-proxy -c vault-agent-init
```

The init log should show authentication success and rendered files under
`/vault/secrets`.

Then run an OpenClaw provider request through the instance and check proxy logs:

```sh
oc logs -n team-a-claw deployment/instance-proxy
```

Do not print provider API keys or Vault tokens in logs or issues.
