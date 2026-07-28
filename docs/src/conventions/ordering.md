# Startup ordering

Two Kustomizations `dependsOn` nothing: `namespaces`, which is every `Namespace` CR and no
controller, and `substitutions`, which is every `postBuild.substituteFrom` source and no
controller either. A substitution target has to exist before any consumer reconciles, so it
cannot wait on anything. The two controllers that need nothing else from the cluster —
`infisical-operator` and `cert-manager` — sit directly behind `namespaces`.

The real graph, as declared in each `ks.yaml` — thick borders are the roots and the two
sinks, the dashed edge is the one inversion:

```d2
direction: down

namespaces: namespaces\n(no dependsOn) { style.stroke-width: 3 }
substitutions: substitutions\n(no dependsOn) { style.stroke-width: 3 }

infisical-operator-config: infisical-operator-config
cert-manager-config: cert-manager-config
tailscale-operator-config: tailscale-operator-config

nodes: nodes { style.stroke-width: 3 }
actual: nodes/kenaz.k0s/actual

namespaces -> cert-manager
namespaces -> infisical-operator

infisical-operator -> infisical-operator-config
cert-manager -> cert-manager-config

infisical-operator-config -> cert-manager-config
infisical-operator-config -> tailscale-operator-config
infisical-operator-config -> storage
infisical-operator-config -> monitoring
infisical-operator-config -> auth
infisical-operator-config -> actual

tailscale-operator-config -> tailscale-operator: inverted { style.stroke-dash: 3 }
tailscale-operator -> traefik-internal
cert-manager-config -> traefik-internal
cert-manager-config -> auth

traefik-internal -> traefik-edge
traefik-internal -> monitoring
traefik-internal -> actual
traefik-edge -> auth

storage -> actual

substitutions -> traefik-internal
substitutions -> traefik-edge
substitutions -> monitoring
substitutions -> actual
substitutions -> infra-policies

cert-manager -> infra-policies
infisical-operator -> infra-policies
tailscale-operator -> infra-policies
traefik-internal -> infra-policies
traefik-edge -> infra-policies
storage -> infra-policies
monitoring -> infra-policies
auth -> infra-policies

infra-policies -> nodes
infra-policies -> actual
```

Only those two name `namespaces` in their `dependsOn`; everything else reaches it
transitively.

They need nothing from the cluster but a namespace to land in. Their `config-ks.yaml` siblings
are where the ordering actually bites, because those apply CRs the controller must already have
registered CRDs for — except `tailscale-operator-config`, which runs the other way round.

Four edges are less obvious than they look:

- `namespaces` is a root of its own rather than a file next to each component, because
  `infisical-operator` installs its chart with `scopedRBAC: true` — Helm emits a Role and
  RoleBinding _inside_ every `scopedNamespaces` entry at install time, and those namespaces
  belong to components that are downstream of `infisical-operator-config`. With the
  `Namespace` CRs held by their consumers the install failed outright on
  `namespaces "auth" not found`.
- `tailscale-operator-config` runs _before_ its operator, inverting the pattern every other
  `config-ks.yaml` follows. It produces the `operator-oauth` Secret the chart's own Deployment
  mounts. Put it downstream and the Helm install waits on a pod that waits on a Secret that waits
  on the install. The rule: what a chart _mounts_ goes upstream of it, what needs the chart's
  _CRDs_ goes downstream.
- Anything that needs an operator _running_, rather than just its credentials present, has to
  name the operator and not the config ahead of it. `traefik-internal` names
  `tailscale-operator` for exactly that reason.
- `substitutions` has no dependencies, and holds every `postBuild.substituteFrom` source in the
  cluster: the `edge-ips` and `int-domain` Secrets, and the `domain` ConfigMap. A substitution
  target must exist before the Kustomization that substitutes from it reconciles, and the obvious
  home — `infra-policies` — is downstream of `traefik-edge`, one of those consumers.

`infra-policies` sits behind every infra controller. Its overlays attach policy to namespaces
that are already there, so the ordering it needs is the controllers': `middleware-ratelimit`
wants Traefik's `Middleware` CRD registered, and the point of the edges as a whole is that a
namespace's default-deny policy lands before anything worth denying. `nodes` then depends on
`infra-policies`.

## What `wait: true` already buys, and why there are no `healthChecks`

Every Kustomization in the tree sets `wait: true` — patched in once by `infra/kustomization.yaml`
— and none sets `healthChecks`. That is deliberate, and the two are alternatives rather than
complements: `wait: true` health-checks **every** resource the Kustomization applied, and Flux
**ignores `healthChecks` entirely when it is set**. Adding a `healthChecks` list would be config
that never runs; getting it to run means `wait: false`, which checks only the resources you
remembered to name.

The gap `healthChecks` would seem to close — "the HelmRelease is Ready but its pods are still
starting" — is closed further upstream. helm-controller's `install.disableWait` and
`upgrade.disableWait` both default to `false`, so it polls the chart's workloads with kstatus and
only then reports the `HelmRelease` Ready. So a `dependsOn` edge onto a chart-based component
already means that chart's Deployments and DaemonSets are up.

`local-path` is the one piece that cannot come from Flux at all: monitoring, `auth` and
`nodes/kenaz.k0s/actual` bind PVCs on their first reconcile, and nothing in the Flux-managed
tree can provision a StorageClass for itself. `ansible/roles/local_path_provisioner` installs it
during [Cold bootstrap](../operations/setup.md) step 6.

## Where a new component goes

- Has an `InfisicalStaticSecret`: downstream of `infisical-operator-config`, same as `storage`
  and `monitoring`. Also add its namespace to the right tier's `scopedNamespaces` — see
  [Cluster infrastructure](../gitops/infra.md#infisical-operator).
- Needs a certificate: downstream of `cert-manager-config`.
- Needs ingress: downstream of `traefik-internal`, or `traefik-edge` if it is public-facing.
- Needs none of the above: it can be another root. Check first — most things eventually need a
  cert or an ingress, and both have prerequisites.

Whatever you pick, add the component's namespace to `infra/namespaces/app/namespaces.yaml` —
nothing else declares it. If anything under `infra/policies/namespaces/` targets that namespace,
add the component to `infra/policies-ks.yaml`'s `dependsOn` too, so the policy lands with the
workload rather than ahead of it.
