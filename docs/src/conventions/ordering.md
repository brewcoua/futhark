# Startup ordering

The `dependsOn` graph the whole tree reconciles in, why each non-obvious edge exists, and where a
new component belongs in it.

Two Kustomizations `dependsOn` nothing: `namespaces`, which is every `Namespace` CR and no
controller, and `substitutions`, which is every `postBuild.substituteFrom` source and no
controller either. A substitution target has to exist before any consumer reconciles, so it cannot
wait on anything. The two controllers that need nothing else from the cluster,
`infisical-operator` and `cert-manager`, sit directly behind `namespaces`.

The real graph, as declared in each `ks.yaml`. Green marks the boundary: the two roots and the two
sinks. Purple dashed marks a `config-ks.yaml`. Blue is the ordering spine, the chain that actually
has to reconcile in sequence. The two grey bundles are not part of that chain and are drawn back
so it reads through them: dashed grey is a substitution source that only has to exist, and solid
grey is the fan-in onto `infra-policies`.

```d2
vars: {
  d2-config: {
    layout-engine: elk
  }
}

direction: down

classes: {
  boundary: {
    style: {
      stroke-width: 3
      stroke: seagreen
      fill: honeydew
    }
  }
  config: {
    style: {
      stroke-dash: 3
      stroke: mediumpurple
      fill: lavender
    }
  }
  presence: {
    style: {
      stroke: dimgray
      stroke-dash: 4
    }
  }
  bulk: {
    style.stroke: dimgray
  }
}

namespaces: namespaces\n(no dependsOn) { class: boundary }
substitutions: substitutions\n(no dependsOn) { class: boundary }

infisical-operator-config: infisical-operator-config { class: config }
cert-manager-config: cert-manager-config { class: config }
backup-config: backup-config { class: config }

nodes: nodes { class: boundary }
actual: nodes/kenaz.k8s/actual { class: boundary }

namespaces -> cert-manager
namespaces -> infisical-operator

infisical-operator -> infisical-operator-config
cert-manager -> cert-manager-config

infisical-operator-config -> cert-manager-config
infisical-operator-config -> storage
infisical-operator-config -> backup
infisical-operator-config -> monitoring
infisical-operator-config -> auth
infisical-operator-config -> actual

cert-manager-config -> traefik-internal
cert-manager-config -> auth

traefik-internal -> traefik-edge
traefik-internal -> monitoring
traefik-internal -> actual
traefik-edge -> auth

storage -> actual
backup -> backup-config

substitutions -> traefik-internal { class: presence }
substitutions -> traefik-edge { class: presence }
substitutions -> monitoring { class: presence }
substitutions -> backup { class: presence }
substitutions -> actual { class: presence }
substitutions -> infra-policies { class: presence }

cert-manager -> infra-policies { class: bulk }
infisical-operator -> infra-policies { class: bulk }
traefik-internal -> infra-policies { class: bulk }
traefik-edge -> infra-policies { class: bulk }
storage -> infra-policies { class: bulk }
backup -> infra-policies { class: bulk }
monitoring -> infra-policies { class: bulk }
auth -> infra-policies { class: bulk }

infra-policies -> nodes
infra-policies -> actual
```

Only those two name `namespaces` in their `dependsOn`. Everything else reaches it transitively.

They need nothing from the cluster but a namespace to land in. Their `config-ks.yaml` siblings
are where the ordering actually bites, because those apply CRs the controller must already have
registered CRDs for.

Three edges are less obvious than they look:

- `namespaces` is a root of its own rather than a file next to each component, because
  `infisical-operator` installs its chart with `scopedRBAC: true`. Helm emits a Role and
  RoleBinding _inside_ every `scopedNamespaces` entry at install time, and those namespaces belong
  to components that are downstream of `infisical-operator-config`. With the `Namespace` CRs held
  by their consumers, the install failed outright on `namespaces "auth" not found`.
- A `config-ks.yaml` does not always belong downstream of its controller. The rule is what the
  dependency is _for_: what a chart **mounts** goes upstream of it, what needs the chart's
  **CRDs** goes downstream. A config Kustomization producing a Secret the chart's own Deployment
  mounts has to run first, or the Helm install waits on a pod that waits on a Secret that waits
  on the install. Nothing in the tree currently inverts it, since every `config-ks.yaml` here
  applies CRs, but the inversion is legitimate and is why the rule is stated rather than the
  pattern.
- `substitutions` has no dependencies, and holds every `postBuild.substituteFrom` source in the
  cluster: the `cluster-values` Secret and the `monitoring-sizing` ConfigMap. A substitution target must exist before the Kustomization that substitutes from it
  reconciles, and `traefik-edge`, one of those consumers, is upstream of `infra-policies`, the
  otherwise obvious home for them.

`infra-policies` sits behind every infra controller. Its overlays attach policy to namespaces
that are already there, so the ordering it needs is the controllers'. `middleware-ratelimit` wants
Traefik's `Middleware` CRD registered, and the point of the edges as a whole is that a namespace's
default-deny policy lands before anything worth denying. `nodes` then depends on
`infra-policies`.

## What `wait: true` already buys, and why there are no `healthChecks`

Every Kustomization in the tree sets `wait: true`, patched in once by `infra/kustomization.yaml`,
and none sets `healthChecks`. That is deliberate, and the two are alternatives rather than
complements. `wait: true` health-checks **every** resource the Kustomization applied, and Flux
**ignores `healthChecks` entirely when it is set**. Adding a `healthChecks` list would be config
that never runs. Getting it to run means `wait: false`, which checks only the resources you
remembered to name.

The gap `healthChecks` would seem to close, "the HelmRelease is Ready but its pods are still
starting", is closed further upstream. helm-controller's `install.disableWait` and
`upgrade.disableWait` both default to `false`, so it polls the chart's workloads with kstatus and
only then reports the `HelmRelease` Ready. So a `dependsOn` edge onto a chart-based component
already means that chart's Deployments and DaemonSets are up.

`local-path` is the one piece that cannot come from Flux at all: monitoring, `auth` and
`nodes/kenaz.k8s/actual` bind PVCs on their first reconcile, and nothing in the Flux-managed
tree can provision a StorageClass for itself. It arrives with k3s, whose bundled provisioner
`ansible/roles/k8s_cluster` deliberately leaves enabled, during `just ans k8s`,
[Cold bootstrap](../operations/setup.md) step 9.

## Where a new component goes

- Has an `InfisicalStaticSecret`: downstream of `infisical-operator-config`, same as `storage`
  and `monitoring`. Also add its namespace to the right tier's `scopedNamespaces`. See
  [Cluster infrastructure](../gitops/infra.md#infisical-operator).
- Needs a certificate: downstream of `cert-manager-config`.
- Needs ingress: downstream of `traefik-internal`, or `traefik-edge` if it is public-facing.
- Needs none of the above: it can be another root. Check first. Most things eventually need a
  cert or an ingress, and both have prerequisites.

Whatever you pick, add the component's namespace to `infra/namespaces/app/namespaces.yaml`.
Nothing else declares it. If anything under `infra/policies/namespaces/` targets that namespace,
add the component to `infra/policies-ks.yaml`'s `dependsOn` too, so the policy lands with the
workload rather than ahead of it.

Verify the edge you added: `just fx get` shows the new Kustomization `Ready`, and nothing upstream
of it moved to `Reconciling` and stayed there.
