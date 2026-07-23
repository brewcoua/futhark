# infisical-operator

One shared `InfisicalConnection` (`connection.yaml`), but **two classes of machine identity**,
each a separate `InfisicalAuth` + bridged Secret, so a compromised identity can't read secrets
outside its own scope:

- **`infisical`** (`auth.yaml`) — the infra identity. Infisical project role: read-only on
  `/infra/**` and `/monitoring/**`. Used by every node-agnostic component
  (`infra/authentik`, `infra/cert-manager`, `infra/storage`, `infra/monitoring`, ...).
- **`infisical-<hostname>`** (`nodes/<hostname>.yaml`, one per node) — that node's own identity.
  Infisical project role: read-only on `/nodes/<hostname>/**` only (covers
  `/nodes/<hostname>/apps/<app>` too). Used by that node's own apps
  (`nodes/<hostname>.k0s/<app>/app/secret.yaml`).

Both identity's Universal Auth credentials are bridged from Proton Pass by
`ansible/roles/flux_bootstrap` — never committed. Neither role/identity is Terraform-managed
(this repo has no Infisical provider — see `tofu/README.md`); create them by hand in the
Infisical UI.

An app needing secrets from both scopes uses two `InfisicalStaticSecret` CRs, one per
`infisicalAuthRef` — a single identity is never widened to cover both.

## Adding a node

1. In Infisical: create a machine identity + a project role scoped to read-only on
   `/nodes/<hostname>/**`, assign the role to the identity.
2. Add the two Proton Pass items `futharkd/<hostname>/infisical-client-id` and
   `futharkd/<hostname>/infisical-client-secret` (see `ansible/nodes/README.md`).
3. Add `nodes/<hostname>.yaml` here (copy `nodes/kenaz.yaml`, swap the hostname) and list it
   in `kustomization.yaml`.
4. Re-run `task ans:k0s` to bridge the new node's Secret.
