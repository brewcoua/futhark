# Node apps

What lives under `nodes/`, how it differs from `ansible/nodes/`, and which secrets a node app may
read. The procedure for adding one is
[Adding a node app](../conventions/layout.md#adding-a-node-app).

`nodes/` holds one directory per node that runs its own tenant apps, named `<hostname>.k0s` to
match the `workflow` field in `ansible/nodes/<hostname>/host.yml`. Inside it, one subdirectory per
app: `ks.yaml`, the Flux `Kustomization` CR, plus `app/`, the manifests.

This is a different `nodes/` from `ansible/nodes/`. Ansible's copy is provisioning data, meaning
how to reach and bootstrap the host. This one is what runs once the host exists. See
[Nodes](../ansible/nodes.md).

A node's apps read their secrets from Infisical under `/nodes/<hostname>/`, through that node's
own operator tier in `infisical-node-<hostname>`, never the infra tier. That separation is
enforced by RBAC and an admission policy rather than by convention. See
[Cluster infrastructure](infra.md#infisical-operator).

Not every k0s node gets a directory here. `ogma` runs no tenant apps: Pocket ID is cluster-wide
infra rather than a per-node workload, so it lives under `infra/auth/`, pinned to `ogma` with a
`nodeSelector`.

## `kenaz.k0s`

`kenaz` runs k0s as controller+worker, plus Flux and everything under `infra/`. Its first and
so far only app is `actual` (`nodes/kenaz.k0s/actual/{ks.yaml,app/}`), reading from
`/nodes/kenaz/actual`.

New apps land the same way. The step-by-step is
[Adding a node app](../conventions/layout.md#adding-a-node-app).
