# external-secrets

External Secrets Operator, pointed at OpenBao (`infra/openbao`, a Flux-managed StatefulSet
pinned to `ogma` — see `ansible/roles/openbao/`) via its `vault` provider, reached in-cluster at
`openbao.openbao.svc.cluster.local:8200`. Same two-tier isolation as before, now enforced by
OpenBao **namespaces** rather than path-prefix policies — each namespace has its own `secret/`
kv-v2 mount, its own `kubernetes` auth mount, and its own `reader` policy, so a compromised
binding can't read outside its own namespace by construction:

- **`infra` namespace** (`clustersecretstore-infra.yaml`, store `bao-infra`) — used by every
  node-agnostic component (`infra/cert-manager`, `infra/storage`, `infra/monitoring`, ...).
- **`node-<hostname>` namespace** (`nodes/<hostname>.yaml`, one per k0s node, store
  `bao-node-<hostname>`) — that node's own apps (`nodes/<hostname>.k0s/<app>/app/`).

Every `ClusterSecretStore` authenticates via OpenBao's `kubernetes` auth method as the
`external-secrets` ServiceAccount in this namespace — no long-lived credential lives in-cluster
at all; the k0s API validates the request via TokenReview on every call. An app needing secrets
from both scopes uses two `ExternalSecret`s, one per `secretStoreRef` — a single store's reach is
never widened to cover both.

Namespace + mount + auth-role bootstrap is `ansible/roles/openbao`'s `tasks/namespaces.yml`, run
via `task bao:policy-sync` against the in-cluster OpenBao (`kubectl exec`, no SSH), not
Terraform-managed (this repo has no OpenBao/Vault provider — see `tofu/README.md`).

## Adding a node

1. Re-run `task bao:policy-sync` — it loops every `nodes/*.k0s/` directory and bootstraps any
   `node-<hostname>` namespace that doesn't exist yet.
2. Add `nodes/<hostname>.yaml` here (copy `nodes/kenaz.yaml`, swap the hostname) and list it in
   `kustomization.yaml`.
