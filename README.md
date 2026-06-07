# OpenClaw Vault on OpenShift

This repository contains test-cluster manifests and runbooks for using Vault as
the secret store for OpenClaw instances on OpenShift.

The target architecture separates human and workload authentication:

- Keycloak authenticates human users into the Vault UI and CLI.
- Vault policies let each user manage only their own prefix under the shared
  `users` mount.
- Vault Agent sidecars authenticate to Vault with the OpenClaw proxy pod's
  Kubernetes service account.
- OpenClaw gateway pods do not receive provider credentials.

## Repository layout

```text
manifests/
  keycloak/        Keycloak instance and realm import
  vault/           Vault Helm values
  openclaw/        Example Claw custom resources using vaultRef
scripts/
  keycloak/        Keycloak helper scripts
  vault/           Vault bootstrap/configuration scripts
docs/
  setup.md         End-to-end setup runbook
  onboard-user.md  Admin runbook for adding one user/tenant
  operations.md    Day-2 operations and tenant onboarding
  decision.md      Why Vault is valuable and when to use it
```

## Why Vault

The existing claw-operator proxy already keeps provider credentials out of the
OpenClaw gateway pod. Vault adds a separate secret-management plane where users
can log in with OIDC, manage their own provider keys, and rely on Vault policies
and audit logs while the proxy authenticates as a Kubernetes workload.

Use Vault for shared or hosted OpenClaw deployments where user-owned credential
management and tenant-scoped Vault policy are worth the operational cost. For a
small admin-managed install, Kubernetes SecretRefs plus the existing proxy may
be enough.

See [docs/decision.md](docs/decision.md) for the full comparison and diagram.

## Prerequisites

- OpenShift CLI logged into the target cluster.
- Helm.
- Vault CLI.
- `jq`.
- Red Hat build of Keycloak Operator installed in the `keycloak` namespace.
- OpenClaw operator with Vault Agent injector support deployed.

## Quick Start

1. Review and edit the sample configuration in `env.example`.
2. Deploy Vault:

   ```sh
   helm upgrade -i -n vault vault hashicorp/vault \
     -f manifests/vault/values-vault-openshift.yaml \
     --create-namespace \
     --set server.route.host=vault.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
   ```

3. Initialize and unseal Vault:

   ```sh
   scripts/vault/init-unseal.sh
   ```

4. Deploy Keycloak:

   ```sh
   oc apply -f manifests/keycloak/operator.yaml
   scripts/keycloak/create-local-secrets.sh
   oc apply -k manifests/keycloak
   # After Keycloak is ready and realm-import.yaml has the Vault route:
   oc apply -f manifests/keycloak/realm-import.yaml
   ```

5. Configure Vault OIDC and workload Kubernetes auth:

   ```sh
   cp env.example .env
   # Edit .env, then:
   set -a
   . ./.env
   set +a
   scripts/vault/configure-vault.sh
   ```

6. Create a tenant policy and role:

   ```sh
   scripts/vault/create-tenant.sh team-a team-a-openclaw team-a-claw instance
   ```

7. Apply a Claw example after replacing placeholders:

   ```sh
   oc apply -k manifests/openclaw
   ```

## Secret Path Convention

Use the shared `users` KV v2 mount with one prefix per tenant or user:

```text
users/<tenant>/<secret-name>
```

For KV v2, a `vaultRef` id includes the field name as its final path segment:

```yaml
vaultRef:
  - id: team-a/openrouter/apiKey
```

With `spec.vault.kvMount: users`, Vault Agent reads:

```text
users/data/team-a/openrouter
```

and renders the `apiKey` field into a file for the proxy.

## Security Notes

- Do not commit Vault root tokens, unseal keys, Keycloak client secrets, or
  provider API keys.
- Store generated bootstrap files outside git or in ignored local files.
- Keep user-specific Claw examples under `local/`; that directory is ignored.
- Use a separate Vault role per tenant or per Claw instance.
- Avoid a global role that can read `users/data/*`.
- Keycloak is for human Vault access only. OpenClaw workloads should use Vault
  Agent with Kubernetes service account auth.
