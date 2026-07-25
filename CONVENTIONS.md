# Conventions

Repo-wide rules for the GitOps tree (`flux/`, `infra/`, `nodes/`). A directory's own
`README.md` only documents what's specific to that directory — anything cross-cutting
belongs here instead.

## File names

Only two file names exist for Kubernetes YAML in this repo:

- `ks.yaml` — a Flux `Kustomization` CR, one per directory named for what it reconciles.
- `kustomization.yaml` — a plain kustomize resource list (the name `kustomize build`
  itself requires).

If you're naming a Kubernetes YAML file something else, you're naming it wrong.

## Layout

- `infra/<component>/{ks.yaml, app/}` — one Flux `Kustomization` per component.
- `infra/<component>/{config-ks.yaml, config/}` — only when that component's CRs need
  CRDs the component's own `ks.yaml` can't guarantee exist yet (chicken-and-egg on first
  apply, e.g. `cert-manager`'s `ClusterIssuer`, `external-secrets`'s `ClusterSecretStore`).
- `nodes/<hostname>.k0s/<app>/{ks.yaml, app/}` — one per node's own tenant app. See
  `nodes/README.md`. Cluster-wide infra pinned to a specific node (OpenBao, Pocket ID —
  both on `ogma`) is a `nodeSelector` under `infra/<component>/` instead, not a `nodes/`
  entry — `nodes/` is for tenant workloads, not infra controllers.

## Namespaces

Infra controllers declare their own `app/namespace.yaml`. Node/tenant namespaces are
centralized instead, alongside their NetworkPolicy and RBAC (see below), in
`infra/configs/namespaces/<namespace>/`. Every non-control-plane namespace carries
`futk.eu/tier: infra|node` (+ `futk.eu/node: <hostname>` for node namespaces), mirroring
OpenBao's own `infra`/`node-<hostname>` namespace split
(`ansible/roles/openbao/tasks/namespaces.yml`).

## Network policy

Every non-control-plane namespace gets a default-deny baseline plus explicit opt-in
bridges, assembled per namespace from shared templates in
`infra/configs/namespaces/_templates/`:

- `netpol-default-deny` + `netpol-allow-same-namespace` — always.
- `netpol-allow-from-monitoring` — always, except in `monitoring` itself.
- `netpol-allow-from-ingress-internal` or `netpol-allow-from-ingress-edge` — only if the
  namespace ships an `Ingress`, matching whichever `ingressClassName` it uses.

Kubernetes has no cluster-wide `NetworkPolicy`, so this is one overlay per namespace, not
one file. Egress is left open everywhere (ESO's call to OpenBao, cert-manager's ACME
calls, arbitrary app egress) — the risk that matters in a single-tenant homelab is
inbound.

## Rate limiting

Every namespace with an `Ingress` also composes the `middleware-ratelimit` template from
`infra/configs/namespaces/_templates/` (a Traefik `Middleware`, `average: 100`/`burst: 200`,
per-source-IP) — basic DoS protection, not a precise budget. The Ingress itself must then
reference it explicitly via
`traefik.ingress.kubernetes.io/router.middlewares: <namespace>-ratelimit@kubernetescrd`
(composing the template alone does nothing — Traefik only applies a `Middleware` to routers
that name it). Same-namespace reference only; `traefik-edge`'s `kubernetesCRD` provider
doesn't set `allowCrossNamespace` (unlike `traefik-internal`), so a shared/cross-namespace
Middleware wouldn't resolve there.

## ESO RBAC

The external-secrets chart's own cluster-wide RBAC is disabled
(`infra/external-secrets/app/helmrelease.yaml`'s `values.rbac.create: false`). Instead:

- `infra/external-secrets/app/{clusterrole,role}.yaml` grant ESO only what's genuinely
  cluster-scoped (`ClusterSecretStore`) or scoped to its own namespace.
- The `rbac-eso-writer` template in `infra/configs/namespaces/_templates/` grants ESO
  write access to `Secrets` in one namespace at a time — added to a namespace's overlay
  only if it actually has an `ExternalSecret`.

Secrets access is never cluster-wide.

## Domains

Base domains live only in `config/domain/domain.env` (`DOMAIN`, `INT_DOMAIN`) — shared with
ansible (`ansible/inventory/group_vars/all.yml` reads the same file) — never hardcoded
per-app. `config/domain/kustomization.yaml` wraps it as a reusable Kustomize Component,
centralized under `config/` (not `infra/`) since it isn't infra-only. Flux's
`postBuild.substitute`/`substituteFrom` can't reach `HelmRelease.spec.values`, so domain
injection instead goes through plain kustomize: any `app/` needing a hostname adds
`components: [../../../config/domain]` plus a `replacements` block splicing a key into the
target field — see `infra/monitoring/app/kustomization.yaml` for the pattern. Escape a
literal `$` as `$$` in plain manifests reconciled by a Kustomization.

## Startup ordering

`infra/openbao` is the root of the dependency graph — it `dependsOn` nothing, because
nothing it needs (raft storage, its KMIP seal) lives in the cluster. Everything else
that reads secrets needs it, directly or transitively:

```
openbao -> external-secrets-config -> auth (Pocket ID) -> everything else
                                    -> cert-manager-config -> traefik-internal -> ...
```

A new infra component that reads secrets from OpenBao (has an `ExternalSecret`) belongs
downstream of `external-secrets-config` in its `ks.yaml`'s `dependsOn`, same as
`cert-manager-config`/`storage`/`monitoring` already are. A component that reads no
secrets and has no other prerequisite can be a second root next to `openbao` — but check
first: most things eventually need a cert (`cert-manager-config`) or ingress
(`traefik-internal`), which do have prerequisites.

## Flux `Kustomization` boilerplate

`interval`, `prune`, `sourceRef`, and the `flux-system` namespace are shared by every
Flux `Kustomization` CR and patched in once, from `infra/kustomization.yaml` and
`nodes/kustomization.yaml`. A `ks.yaml` itself declares only `metadata.name`,
`spec.path`, and `spec.dependsOn`.

Exception: `flux/infra/ks.yaml` and `flux/nodes/ks.yaml` keep the full spec. `flux/` has
no `kustomization.yaml` of its own — Flux auto-generates one from `flux/cluster.yaml`'s
`sync.path: flux` — so nothing there can patch them, and adding one would pull
`cluster.yaml` itself into reconciliation.

## Secrets

Apps read secrets from OpenBao via External Secrets Operator, never from a static
credential committed to the repo. Ansible-bridged secrets (the git deploy key, and any
future config bridging needs) are regenerated by the relevant `task ans:*` run, not by
Flux — deliberately outside GitOps reach, since they exist to seed values Flux/apps need
before they can resolve anything themselves.

## Adding a new node app

1. `nodes/<hostname>.k0s/<app>/{ks.yaml, app/}`, `ks.yaml` with `dependsOn: [infra-configs]`
   (plus whatever else the app itself needs, e.g. `traefik-internal`).
2. Add its directory to the sibling `kustomization.yaml`'s `resources:`.
3. `infra/configs/namespaces/<app>/` — a `namespace.yaml` (labeled `futk.eu/tier: node`,
   `futk.eu/node: <hostname>`) plus the default-deny/same-namespace/monitoring netpol
   templates.
4. Add the ingress-bridge template iff `app/` ships an `Ingress`.
5. Add the `rbac-eso-writer` template iff `app/` ships an `ExternalSecret`.
6. Add the new overlay directory to `infra/configs/kustomization.yaml`.
