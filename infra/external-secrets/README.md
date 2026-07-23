# external-secrets

External Secrets Operator, pointed at OpenBao (running on `ogma`, see `nodes/ogma.podman/` and
`ansible/roles/openbao/`) via its `vault` provider. Same two-tier isolation as before, now
enforced by OpenBao **namespaces** rather than path-prefix policies — each namespace has its own
`secret/` kv-v2 mount, its own `kubernetes` auth mount, and its own `reader` policy, so a
compromised binding can't read outside its own namespace by construction:

- **`infra` namespace** (`clustersecretstore-infra.yaml`, store `bao-infra`) — used by every
  node-agnostic component (`infra/authentik`, `infra/cert-manager`, `infra/storage`,
  `infra/monitoring`, ...).
- **`node-<hostname>` namespace** (`nodes/<hostname>.yaml`, one per k0s node, store
  `bao-node-<hostname>`) — that node's own apps (`nodes/<hostname>.k0s/<app>/app/`).

Every `ClusterSecretStore` authenticates via OpenBao's `kubernetes` auth method as the
`external-secrets` ServiceAccount in this namespace — no long-lived credential lives in-cluster
at all; the k0s API validates the request via TokenReview on every call. An app needing secrets
from both scopes uses two `ExternalSecret`s, one per `secretStoreRef` — a single store's reach is
never widened to cover both.

Namespace + mount + auth-role bootstrap is `ansible/roles/openbao`'s `tasks/namespaces.yml`, run
against ogma (`task ans:podman` or `task bao:policy-sync`), not Terraform-managed (this repo has
no OpenBao/Vault provider — see `tofu/README.md`).

## Adding a node

1. Re-run `task bao:policy-sync` — it loops every `workflow: k0s` host in inventory and bootstraps
   any namespace that doesn't exist yet.
2. Add `nodes/<hostname>.yaml` here (copy `nodes/kenaz.yaml`, swap the hostname) and list it in
   `kustomization.yaml`.
