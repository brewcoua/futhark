# Node apps

`nodes/` holds one directory per node that runs its own tenant apps, named `<hostname>.k0s` to
match the `workflow` field in `ansible/nodes/<hostname>/host.yml`. Inside it, one
subdirectory per app: `ks.yaml` (the Flux `Kustomization` CR) plus `app/` (the manifests).

This is a different `nodes/` from `ansible/nodes/`. Ansible's copy is provisioning data — how
to reach and bootstrap the host. This one is what runs once the host exists. See
[Nodes](../ansible/nodes.md).

A node's apps read their secrets from the OpenBao namespace `node-<hostname>` through that
node's own `ClusterSecretStore`, `bao-node-<hostname>` — not the shared `bao-infra` one. See
[Cluster infrastructure](infra.md).

Not every k0s node gets a directory here. `ogma` runs no tenant apps: OpenBao and Pocket ID
are cluster-wide infra rather than per-node workloads, so they live under `infra/openbao/` and
`infra/auth/`, each pinned to `ogma` with a `nodeSelector`.

## `kenaz.k0s`

`kenaz` runs k0s as controller+worker, plus Flux and everything under `infra/`. Its first and
so far only app is `actual` (`nodes/kenaz.k0s/actual/{ks.yaml,app/}`), reading from OpenBao
namespace `node-kenaz`.

New apps land the same way — the step-by-step is
[Adding a node app](../conventions/layout.md#adding-a-node-app).
