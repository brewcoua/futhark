# Layout and naming

Rules for the GitOps tree — `flux/`, `infra/`, `nodes/`.

## File names

Only two file names exist for Kubernetes YAML in this repo:

- `ks.yaml` — a Flux `Kustomization` CR, one per directory, named for what it reconciles.
- `kustomization.yaml` — a plain kustomize resource list (the name `kustomize build` itself
  requires).

If you are naming a Kubernetes YAML file something else, you are naming it wrong.

## Directory layout

- `infra/<component>/{ks.yaml, app/}` — one Flux `Kustomization` per component.
- `infra/<component>/{config-ks.yaml, config/}` — only when that component's CRs need CRDs
  its own `ks.yaml` cannot guarantee exist yet. This is a chicken-and-egg on first apply, and
  it is why `cert-manager`'s `ClusterIssuer` and `infisical-operator`'s `InfisicalConnection`
  each sit behind a second Kustomization.
- `nodes/<hostname>.k0s/<app>/{ks.yaml, app/}` — one directory per node app. See
  [Node apps](../gitops/nodes.md).

Cluster-wide infra that happens to be pinned to a specific node is not a `nodes/` entry.
Pocket ID runs only on `ogma`, and expresses that as a `nodeSelector` under `infra/`. `nodes/` is for tenant workloads, not infra controllers.

## Flux `Kustomization` boilerplate

`interval`, `prune`, `sourceRef`, and the `flux-system` namespace are shared by every Flux
`Kustomization` CR, so they are patched in once — from `infra/kustomization.yaml` and
`nodes/kustomization.yaml`. A `ks.yaml` itself declares only `metadata.name`, `spec.path`,
and `spec.dependsOn`.

`flux/infra/ks.yaml` and `flux/nodes/ks.yaml` are the exception and keep their full spec.
`flux/` has no `kustomization.yaml` of its own to patch from — Flux auto-generates one from
`flux/cluster.yaml`'s `sync.path: flux` — and adding a real one would pull `cluster.yaml`
itself into reconciliation.

## Adding a node app

1. Create `nodes/<hostname>.k0s/<app>/{ks.yaml, app/}`. The `ks.yaml` needs
   `dependsOn: [infra-policies]`, plus whatever the app itself needs — usually
   `traefik-internal` and `infisical-operator-config`. `nodes/kenaz.k0s/actual/ks.yaml` is the
   worked example.
2. Add the directory to the sibling `kustomization.yaml`'s `resources:`.
3. Add the namespace to `infra/namespaces/app/namespaces.yaml`, labeled `futk.eu/tier: node`
   and `futk.eu/node: <hostname>`. Then create `infra/policies/namespaces/<app>/` with the
   default-deny, same-namespace and from-monitoring [network policy](network-policy.md)
   templates.
4. Add the ingress-bridge template only if `app/` ships an `Ingress`.
5. If `app/` ships an `InfisicalStaticSecret`, add its namespace to the right tier's
   `scopedNamespaces` in `infra/infisical-operator/app/` — the operator has no RBAC there
   otherwise.
6. Add the new overlay directory to `infra/policies/kustomization.yaml`.
