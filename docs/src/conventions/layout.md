# Layout and naming

Rules for the GitOps tree: `flux/`, `infra/` and `nodes/`. Follow them when adding a component or
a node app, so `kustomize build` passes and Flux reconciles in the right order.

## File names

Only two file names exist for Kubernetes YAML in this repo:

- `ks.yaml`, a Flux `Kustomization` CR, one per directory, named for what it reconciles.
- `kustomization.yaml`, a plain kustomize resource list, which is the name `kustomize build`
  itself requires.

If you are naming a Kubernetes YAML file something else, you are naming it wrong.

## Directory layout

- `infra/<component>/{ks.yaml, app/}`: one Flux `Kustomization` per component.
- `infra/<component>/{config-ks.yaml, config/}`: only when that component's CRs need CRDs its own
  `ks.yaml` cannot guarantee exist yet. This is a chicken-and-egg on first apply, and
  it is why `cert-manager`'s `ClusterIssuer` and `infisical-operator`'s `InfisicalConnection`
  each sit behind a second Kustomization.
- `infra/<component>/app/<workload>/`: subdivide `app/` when a component reconciles several
  distinct workloads. One directory per workload, each a plain `kustomization.yaml` resource
  list. The component still has exactly one Flux `Kustomization`, one `dependsOn` set and one
  `postBuild`. `monitoring` is the case here, with five workloads that start together and share a
  namespace but are read and edited one at a time. Anything genuinely shared by all of them, such
  as its `HelmRepository` list, stays flat in `app/`. Each subdirectory has to `kustomize build`
  on its own, because pre-commit builds every directory holding a `kustomization.yaml`. That is
  also why a reusable Component cannot live under `infra/`. `config/` is where those go.
- `nodes/<hostname>.k0s/<app>/{ks.yaml, app/}`: one directory per node app. See
  [Node apps](../gitops/nodes.md).

Cluster-wide infra that happens to be pinned to a specific node is not a `nodes/` entry.
Pocket ID runs only on `ogma`, and expresses that as a `nodeSelector` under `infra/`. `nodes/` is for tenant workloads, not infra controllers.

## Flux `Kustomization` boilerplate

`interval`, `prune`, `sourceRef`, and the `flux-system` namespace are shared by every Flux
`Kustomization` CR, so they are patched in once, from `infra/kustomization.yaml` and
`nodes/kustomization.yaml`. A `ks.yaml` itself declares only `metadata.name`, `spec.path`,
and `spec.dependsOn`.

`flux/infra/ks.yaml` and `flux/nodes/ks.yaml` are the exception and keep their full spec.
`flux/` has no `kustomization.yaml` of its own to patch from, because Flux auto-generates one from
`flux/cluster.yaml`'s `sync.path: flux`, and adding a real one would pull `cluster.yaml` itself
into reconciliation.

## Version pins

One rule, everywhere: **nothing floats.** Every chart version, image, provider constraint,
collection and release binary names an exact version, so the commit is the record of what runs.
A range is a version the repo cannot state.

- **Container images pin `tag@sha256:…`.** The tag stays for readability; the digest is what
  actually resolves. A tag alone can be repointed at a different binary, and Flux would never
  reconcile, because nothing it watches changed.
- **Helm charts pin `MAJOR.MINOR.PATCH`.** A chart patch is still a template change reaching the
  cluster, and under a `MAJOR.MINOR.*` range it arrived with no commit behind it.

Each chart pin carries a comment recording the chart-to-app mapping, such as
`# chart 41.0.2 -> Traefik v3.7.6`, so what a bump changes is readable without opening the chart.
Where a chart's image tag defaults to `.Chart.AppVersion`, as `csi-driver-rclone` does, that
mapping is the only place the app version appears at all.

Keeping this many exact pins current by hand is not the intent. Renovate opens the bumps. See
[Dependency updates](updates.md).

## Adding a node app

1. Create `nodes/<hostname>.k0s/<app>/{ks.yaml, app/}`. The `ks.yaml` needs
   `dependsOn: [infra-policies]`, plus whatever the app itself needs, usually `traefik-internal`
   and `infisical-operator-config`. `nodes/kenaz.k0s/actual/ks.yaml` is the worked example.
2. Add the directory to the sibling `kustomization.yaml`'s `resources:`.
3. Add the namespace to `infra/namespaces/app/namespaces.yaml`, labeled `futk.eu/tier: node`
   and `futk.eu/node: <hostname>`. Then create `infra/policies/namespaces/<app>/` with the
   default-deny, same-namespace and from-monitoring [network policy](network-policy.md)
   templates.
4. Add the ingress-bridge template only if `app/` ships an `Ingress`.
5. If `app/` ships an `InfisicalStaticSecret`, add its namespace to the right tier's
   `scopedNamespaces` in `infra/infisical-operator/app/`. The operator has no RBAC there
   otherwise.
6. Add the new overlay directory to `infra/policies/kustomization.yaml`.

Verify: `pre-commit run kustomize-build --all-files` passes, then after pushing,
`just fx failing` is empty and the app's pods reach `Running`.
