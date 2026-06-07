# Operations

## Tenant Model

Use one Vault workload role per tenant or per Claw instance. Avoid a shared
role that can read all tenant paths.

Recommended path convention:

```text
users/<tenant>/<secret-name>
```

Recommended Vault role convention:

```text
<tenant>-openclaw
```

For example:

```text
tenant: team-a
role: team-a-openclaw
Claw namespace: team-a-claw
Claw service account: instance
Vault path: users/team-a/openrouter
vaultRef id: team-a/openrouter/apiKey
```

## Supported Provider Secrets

The current Vault integration supports Vault Agent-rendered credentials whose
value is a string field read from Vault. Tenants only need to create the
secrets and Claw credential entries for providers they use:

```sh
vault kv put users/team-a/openrouter apiKey="<openrouter-api-key>"
vault kv put users/team-a/openai apiKey="<openai-api-key>"
vault kv put users/team-a/anthropic apiKey="<anthropic-api-key>"
vault kv put users/team-a/google apiKey="<google-api-key>"
vault kv put users/team-a/vertex credentialsJson=@gcp-credentials.json
```

Matching optional `vaultRef` ids:

```yaml
credentials:
  - name: openrouter
    provider: openrouter
    vaultRef:
      - id: team-a/openrouter/apiKey
  - name: openai
    provider: openai
    vaultRef:
      - id: team-a/openai/apiKey
  - name: anthropic
    provider: anthropic
    vaultRef:
      - id: team-a/anthropic/apiKey
  - name: google
    provider: google
    vaultRef:
      - id: team-a/google/apiKey
```

Google Vertex Anthropic is not an Anthropic API-key credential. It uses
`type: gcp`, a GCP project/location, and a GCP service account or authorized
user credential JSON. Store the full JSON document in a Vault string field and
reference that field with `vaultRef`.

## Onboard a Tenant

1. Create or identify the OpenShift namespace that will hold the Claw.
2. Create the Vault workload role:

   ```sh
   scripts/vault/create-tenant.sh team-a team-a-openclaw team-a-claw instance
   ```

3. Add the user to the `vault-users` Keycloak group.
4. Ask the user to write their provider secret:

   ```sh
   vault kv put users/team-a/openrouter apiKey="<provider-api-key>"
   ```

5. Configure the Claw with `spec.vault.authRole: team-a-openclaw` and
   `spec.vault.kvMount: users`, plus `vaultRef.id:
   team-a/openrouter/apiKey`.

## Human Access

Humans authenticate to Vault through Keycloak OIDC. Vault maps Keycloak group
membership to the `vault-user-sandbox` policy.

This policy uses the OIDC alias name, so the user can manage only the prefix
matching their Keycloak username under the shared `users` mount.

For individual self-service tenants, align the prefix with the Keycloak
username. If a shared team prefix is needed, create an explicit tenant-specific
human policy for that group.

## Workload Access

Vault Agent sidecars in OpenClaw proxy pods authenticate to Vault with
Kubernetes service account auth. The Vault role is bound to the service account
name and namespace:

```text
<namespace>/<service-account>
```

The operator creates a service account with the same name as the Claw instance
when Vault auth is configured.

The expected workload setup is:

```sh
vault auth list | grep '^kubernetes/'
vault read auth/kubernetes/role/<tenant>-openclaw
vault policy read openclaw-<tenant>-read
```

The role must include:

```text
bound_service_account_names: <claw-name>
bound_service_account_namespaces: <claw-namespace>
policies: openclaw-<tenant>-read
```

## Rotation

Provider secret rotation:

```sh
vault kv put users/team-a/openrouter apiKey="<new-provider-api-key>"
```

Vault Agent renders provider secrets into files in the proxy pod, so provider
key changes do not require a new Kubernetes Secret. Restart the proxy if you
need the init container to fail fast on missing data or want an immediate
one-shot verification.

Keycloak Vault client secret rotation:

1. Update the `vault-oidc-client` Secret in the `keycloak` namespace.
2. Update the Vault OIDC config:

   ```sh
   scripts/vault/configure-vault.sh
   ```

Vault root token rotation/unseal material should follow the test cluster's
Vault administration process.

## Troubleshooting

Check Keycloak:

```sh
oc get keycloak,keycloakrealmimport,pods,route -n keycloak
oc logs -n keycloak deployment/rhbk-operator
```

Check Vault:

```sh
oc get pods,route -n vault
vault status
vault auth list
vault secrets list
```

Check a Vault workload role:

```sh
vault read auth/kubernetes/role/team-a-openclaw
```

Check OpenClaw proxy configuration:

```sh
oc get deployment -n team-a-claw instance-proxy -o yaml
oc logs -n team-a-claw deployment/instance-proxy
oc logs -n team-a-claw deployment/instance-proxy -c vault-agent-init
```

Common issues:

- `permission denied`: Vault role policy does not cover the `vaultRef` path.
- Vault Agent init `permission denied`: the role service account name,
  namespace, policy, or auth mount does not match the proxy pod.
- Vault Agent init `Code: 403` for `/v1/auth/kubernetes/login`: the Kubernetes
  auth role or policy does not match the proxy pod. Check
  `vault read auth/kubernetes/role/<role>`.
- OIDC redirect failure: the Vault route was not added to the Keycloak client's
  redirect URI list or the Vault OIDC role.
- `claim "preferred_username" not found in token`: the Keycloak Vault client
  is not mapping `preferred_username` into the OIDC token.
- `Invalid scopes`: Vault is requesting scopes that are not available to the
  Keycloak Vault client. The setup uses the `groups` client scope as a default
  client scope and leaves Vault `oidc_scopes` empty.
- Vault UI can list top-level KV mount entries broadly in OSS Vault; users
  should navigate directly to their own prefix.
