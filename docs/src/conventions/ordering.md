# Startup ordering

There is no single root any more. Four Kustomizations `dependsOn` nothing, because nothing they
need lives in the cluster: `infisical-operator`, `external-secrets`, `cert-manager`,
`tailscale-operator` — plus `edge-ips`, which is one encrypted Secret and no controller at all.

The real graph, as declared in each `ks.yaml`:

```text
infisical-operator ─> infisical-operator-config ─┬─> cert-manager-config ──┐
cert-manager ────────────────────────────────────┘                         │
                                                 │                         ├─> traefik-internal ─> traefik-edge ─> auth
tailscale-operator ─> tailscale-operator-config ─┘                         │
                                                 ├─> storage               │
                                                 └─> monitoring (also needs traefik-internal, edge-ips)
edge-ips ─────────────────────────────────────────────────────> traefik-edge

external-secrets ─┬─> external-secrets-config
cert-manager ─────┘

everything above ──> infra-configs ──> nodes
```

Each root installs a controller that needs nothing from the cluster. Their `config-ks.yaml`
siblings are where the ordering actually bites, because those apply CRs the controller must
already have registered CRDs for.

Two edges are less obvious than they look:

- `external-secrets-config` depends on `cert-manager`, not on anything secret-related. The
  Bitwarden store talks to `bitwarden-sdk-server` over HTTPS, and that certificate comes from a
  `SelfSigned` issuer — deliberately not the ACME path, which would need the Bunny token that a
  secret store is supposed to deliver.
- `edge-ips` has no dependencies and nothing depends on it except its two consumers. A
  `postBuild.substituteFrom` target must exist before the Kustomization that substitutes from it
  reconciles, and the obvious home — `infra-configs` — is downstream of `traefik-edge`, one of
  those consumers.

`infra-configs` sits behind every infra controller, not for secrets but for namespaces: each
overlay under `infra/configs/` sets kustomize's top-level `namespace:` field, so the target
`Namespace` must already exist or the entire overlay fails to apply. `nodes` then depends on
`infra-configs`, which is what guarantees a node app's namespace and its default-deny policy
land before the app does.

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

Whatever you pick, if the component declares its own namespace and anything under
`infra/configs/namespaces/` targets it, add it to `infra/configs-ks.yaml`'s `dependsOn` too.
