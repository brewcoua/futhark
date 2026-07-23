# nodes

One directory per node, named `<hostname>.<workflow>` (matching the `workflow` field in
`ansible/nodes/<hostname>/host.yml`), holding whatever that node actually runs.

This is a different `nodes/` from `ansible/nodes/`: Ansible's copy is provisioning data
(identity, IP, how to reach and bootstrap the host). This one is the workload definition
— what runs once the host exists. A node's `workflow` decides the shape of its directory:

- `k0s` — kustomize manifests, one subdirectory per app: `ks.yaml` (the Flux
  `Kustomization` CR) + `app/` (the actual manifests). See `flux/README.md` for the
  `ks.yaml` convention this follows.
- `podman` — `quadlets/` (Podman Quadlet `.container`/`.volume` units) + `config/`, synced onto
  the node by that node's `futhark-gitops-pull` timer (`ansible/roles/gitops_pull`) rather than
  by Flux — see `ogma.podman/README.md` for the concrete shape and the pull mechanism.

A `k0s` node's own apps read their secrets from OpenBao namespace `node-<hostname>`, via that
node's own `ClusterSecretStore` (`bao-node-<hostname>`, not the shared `bao-infra` one) — see
`infra/external-secrets/README.md`.

## ogma.podman

Standalone Podman node running OpenBao, the secrets backend every other node/app reads from —
see `ogma.podman/README.md`.

## kenaz.k0s

Currently empty — `kenaz` runs k0s + Flux + External Secrets Operator (`infra/`), but no
apps yet. First app lands here as `kenaz.k0s/<app>/{ks.yaml,app/}`, reading its secrets from
OpenBao namespace `node-kenaz` via the `bao-node-kenaz` `ClusterSecretStore`.
