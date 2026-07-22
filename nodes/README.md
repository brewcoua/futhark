# nodes

One directory per node, named `<hostname>.<workflow>` (matching the `workflow` field in
`ansible/nodes/<hostname>/host.yml`), holding whatever that node actually runs.

This is a different `nodes/` from `ansible/nodes/`: Ansible's copy is provisioning data
(identity, IP, how to reach and bootstrap the host). This one is the workload definition
— what runs once the host exists. A node's `workflow` decides the shape of its directory:

- `k0s` — kustomize manifests, one subdirectory per app: `ks.yaml` (the Flux
  `Kustomization` CR) + `app/` (the actual manifests). See `flux/README.md` for the
  `ks.yaml` convention this follows.
- `podman` — not built yet; would hold compose/quadlet files instead. The point of a
  tech-agnostic top-level `nodes/` is that this doesn't require restructuring anything
  above it when it shows up.

## kenaz.k0s

Currently empty — `kenaz` runs k0s + Flux + the Infisical Operator (`infra/`), but no
apps yet. First app lands here as `kenaz.k0s/<app>/{ks.yaml,app/}`.
