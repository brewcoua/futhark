# nodes

One directory per node that runs its own tenant apps, named `<hostname>.k0s` (matching the
`workflow` field in `ansible/nodes/<hostname>/host.yml`) — a subdirectory per app: `ks.yaml`
(the Flux `Kustomization` CR) + `app/` (the actual manifests). See
[`CONVENTIONS.md`](../CONVENTIONS.md) for the `ks.yaml`/namespace/network-policy conventions
this follows.

This is a different `nodes/` from `ansible/nodes/`: Ansible's copy is provisioning data
(identity, IP, how to reach and bootstrap the host). This one is the workload definition —
what runs once the host exists.

A node's own apps read their secrets from OpenBao namespace `node-<hostname>`, via that
node's own `ClusterSecretStore` (`bao-node-<hostname>`, not the shared `bao-infra` one) — see
`infra/external-secrets/README.md`.

Not every k0s node gets a directory here: `ogma` runs no tenant apps — OpenBao and Pocket ID
are cluster-wide infra, not per-node workloads, so they live under `infra/openbao/` and
`infra/auth/` instead, each pinned to `ogma` via `nodeSelector`.

## kenaz.k0s

`kenaz` runs k0s (controller+worker) + Flux + External Secrets Operator (`infra/`). Its first
(and so far only) app is `actual` (`kenaz.k0s/actual/{ks.yaml,app/}`), reading its secrets from
OpenBao namespace `node-kenaz` via the `bao-node-kenaz` `ClusterSecretStore`. New apps land the
same way, one directory per app: `<app>/ks.yaml` + `<app>/app/` — add the app's directory to
the sibling `kustomization.yaml`'s `resources:`.
