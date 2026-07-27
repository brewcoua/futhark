# Startup ordering

Two Kustomizations `dependsOn` nothing: `namespaces`, which is every `Namespace` CR and no
controller, and `edge-ips`, which is one encrypted Secret and no controller either. The three
controllers that need nothing else from the cluster — `infisical-operator`, `external-secrets`,
`cert-manager` — sit directly behind `namespaces`.

The real graph, as declared in each `ks.yaml`:

```text
namespaces ─┬─> cert-manager ───────────────────────────────────────────┐
            │                                                           ├─> cert-manager-config ─┐
            ├─> infisical-operator ─> infisical-operator-config ─┬──────┘                        │
            │                                                    │                               ├─> traefik-internal ─> traefik-edge ─> auth
            │                                                    ├─> tailscale-operator-config   │
            │                                                    │      └─> tailscale-operator ──┘
            │                                                    ├─> storage
            │                                                    └─> monitoring (also needs traefik-internal, edge-ips)
            └─> external-secrets-certs ─> external-secrets ─> external-secrets-config
                (certs also needs cert-manager)

edge-ips ────────────────────────────────────> traefik-edge, monitoring

everything above ──> infra-configs ──> nodes
```

Only those three name `namespaces` in their `dependsOn`; everything else reaches it
transitively.

They need nothing from the cluster but a namespace to land in. Their `config-ks.yaml` siblings
are where the ordering actually bites, because those apply CRs the controller must already have
registered CRDs for — except `tailscale-operator-config`, which runs the other way round.

Five edges are less obvious than they look:

- `namespaces` is a root of its own rather than a file next to each component, because
  `infisical-operator` installs its chart with `scopedRBAC: true` — Helm emits a Role and
  RoleBinding _inside_ every `scopedNamespaces` entry at install time, and those namespaces
  belong to components that are downstream of `infisical-operator-config`. With the
  `Namespace` CRs held by their consumers the install failed outright on
  `namespaces "auth" not found`.
- `tailscale-operator-config` and `external-secrets-certs` run _before_ their operator,
  inverting the pattern every other `config-ks.yaml` follows. Each produces a Secret the chart's
  own Deployment mounts — `operator-oauth` for the tailscale operator, and the
  `bitwarden-tls-certs` that ESO's `bitwarden-sdk-server` sidecar serves HTTPS with. Put either
  one downstream and the Helm install waits on a pod that waits on a Secret that waits on the
  install. The rule: what a chart _mounts_ goes upstream of it, what needs the chart's _CRDs_
  goes downstream. ESO's `ClusterSecretStore` is the second kind, so it stays in `config/`.
- Anything that needs one of those two operators _running_, rather than just its credentials
  present, has to name the operator and not the config ahead of it. `traefik-internal` names
  `tailscale-operator` for exactly that reason.
- The `bitwarden-sdk-server` certificate is issued by a `SelfSigned` Issuer, deliberately not
  the ACME path — that would need the Bunny token, which is itself something a secret store is
  supposed to deliver.
- `edge-ips` has no dependencies and nothing depends on it except its two consumers. A
  `postBuild.substituteFrom` target must exist before the Kustomization that substitutes from it
  reconciles, and the obvious home — `infra-configs` — is downstream of `traefik-edge`, one of
  those consumers.

`infra-configs` sits behind every infra controller. Its overlays attach policy to namespaces
that are already there, so the ordering it needs is the controllers': `middleware-ratelimit`
wants Traefik's `Middleware` CRD registered, and the point of the edges as a whole is that a
namespace's default-deny policy lands before anything worth denying. `nodes` then depends on
`infra-configs`.

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
nothing else declares it. If anything under `infra/configs/namespaces/` targets that namespace,
add the component to `infra/configs-ks.yaml`'s `dependsOn` too, so the policy lands with the
workload rather than ahead of it.
