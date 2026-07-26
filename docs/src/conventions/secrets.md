# Secrets

This repository is public. Nothing in it is a credential, and nothing in it is an identifying
value either — no real addresses, endpoints, account or key identifiers. Files refer to where
a value lives; they never inline it.

There are two stores, used at different times.

## Proton Pass — bootstrap

Anything needed before the cluster can resolve secrets for itself comes from a Proton Pass
vault, addressed as `pass://<vault>/<item>/<field>`. The pointer is committed; the value is
resolved at runtime and never written to disk.

Two resolvers, one per plane:

- **Ansible** — the `protonpass` lookup plugin (`ansible/plugins/lookup/protonpass.py`,
  registered by `lookup_plugins = plugins/lookup` in `ansible/ansible.cfg`). It shells out to
  `pass-cli` and rejects any reference that does not start with `pass://`. Used for the admin
  SSH identity, the tailnet MagicDNS suffix, each node's IP, the Flux git deploy key, the
  OpenBao KMIP seal material, and the OpenBao root token.
- **OpenTofu** — `pass-cli run --env-file secrets.env -- tofu <cmd>`. Each module commits a
  `secrets.env` holding pointers only. See [Rules for every module](../tofu/index.md).

`.taskfiles/bao/Taskfile.yaml`'s `bao:kv` uses a third form, `pass-cli item view` piped into
`kubectl exec` over **stdin** — never argv, which would put the root token in the process
table.

## OpenBao — runtime

Apps read their secrets from OpenBao through External Secrets Operator, never from a static
credential committed to the repo. The store an app uses depends on its tier:

- `bao-infra` (OpenBao namespace `infra`) — every node-agnostic component.
- `bao-node-<hostname>` (OpenBao namespace `node-<hostname>`) — that node's own apps.

Each OpenBao namespace has its own `secret/` kv-v2 mount, its own `kubernetes` auth mount and
its own `reader` policy, so a compromised binding cannot read outside its namespace by
construction. An app needing both scopes uses two `ExternalSecret`s, one per `secretStoreRef`
— a store's reach is never widened to cover both.

No long-lived credential lives in-cluster: every `ClusterSecretStore` authenticates via
OpenBao's `kubernetes` auth method as the `external-secrets` ServiceAccount, and the k0s API
validates each request with a TokenReview.

Two secrets are deliberately outside GitOps reach, because they exist to seed values Flux
needs before it can resolve anything: the git deploy key and OpenBao's KMIP seal material.
Both are (re)created by the relevant `task ans:*` run, not by Flux.

## ESO RBAC

The external-secrets chart's own cluster-wide RBAC is disabled — `values.rbac.create: false`
in `infra/external-secrets/app/helmrelease.yaml`. In its place:

- `infra/external-secrets/app/{clusterrole,role}.yaml` grant ESO only what is genuinely
  cluster-scoped (`ClusterSecretStore`) or scoped to its own namespace.
- The `rbac-eso-writer` template in `infra/configs/namespaces/_templates/` grants ESO write
  access to `Secret`s in one namespace at a time, and is added to a namespace's overlay only
  if that namespace actually has an `ExternalSecret`.

ESO's access to secrets is never cluster-wide.

## Values that are identifying but not secret

A public IP is not a credential, but publishing it here would still tie this repo to a
machine. The rule extends to every file type:

- In a tofu module, set it as `TF_VAR_<name>=pass://...` in `secrets.env`.
- In Ansible, use a `protonpass` lookup — that is why `ansible/nodes/<hostname>/host.yml`
  carries `ip: "{{ lookup('protonpass', ...) }}"` rather than a literal.
- In the cluster, use a placeholder. `infra/traefik-edge` and `infra/monitoring` reference
  `${PUBLIC_IP}` and `${MESH_IP}`, substituted by `postBuild.substituteFrom` from an
  `edge-ips` ConfigMap that `ansible/roles/flux_bootstrap` pushes straight into `flux-system`
  — into the cluster, never into git.

A genuinely non-identifying constant that is shared across the repo is read from its
committed source instead of duplicated. The base domain is the only one, and it lives in
`config/domain/domain.env` — see [Domains](domains.md).

## Adding a new secret

1. Put the value in the Proton Pass vault if something needs it before the cluster is up;
   otherwise put it in OpenBao under the right namespace (`task bao:kv -- put -namespace=...`).
2. Reference it by pointer — `pass://` in Ansible or `secrets.env`, an `ExternalSecret` in the
   cluster.
3. If it is an `ExternalSecret` in a namespace that had none, add the `rbac-eso-writer`
   template to that namespace's overlay.
4. Confirm gitleaks is happy: `pre-commit run gitleaks --all-files`.
