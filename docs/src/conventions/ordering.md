# Startup ordering

`infra/openbao` is the root of the dependency graph. It `dependsOn` nothing, because nothing
it needs — raft storage, its KMIP seal — lives in the cluster. Everything that reads secrets
needs it, directly or transitively.

The real graph, as declared in each `ks.yaml`:

```text
openbao ─┐
         ├─> external-secrets-config ─┬─> cert-manager-config ──┐
external-secrets ─┘                   │                         ├─> traefik-internal ─> traefik-edge ─> auth
cert-manager ─────────────────────────┘                         │
tailscale-operator ─> tailscale-operator-config ────────────────┘
                                      ├─> storage
                                      └─> monitoring (also needs traefik-internal)

everything above ──> infra-configs ──> nodes
```

`openbao`, `external-secrets`, `cert-manager` and `tailscale-operator` are the four roots —
each installs a controller that needs nothing from the cluster. Their `config-ks.yaml`
siblings are where the ordering actually bites, because those apply CRs the controller must
already have registered CRDs for.

`infra-configs` sits behind every infra controller, not for secrets but for namespaces: each
overlay under `infra/configs/` sets kustomize's top-level `namespace:` field, so the target
`Namespace` must already exist or the entire overlay fails to apply. `nodes` then depends on
`infra-configs`, which is what guarantees a node app's namespace and its default-deny policy
land before the app does.

## Where a new component goes

- Reads secrets from OpenBao (has an `ExternalSecret`): downstream of
  `external-secrets-config`, same as `storage` and `monitoring`.
- Needs a certificate: downstream of `cert-manager-config`.
- Needs ingress: downstream of `traefik-internal`, or `traefik-edge` if it is public-facing.
- Needs none of the above: it can be a fifth root next to `openbao`. Check first — most
  things eventually need a cert or an ingress, and both have prerequisites.

Whatever you pick, if the component declares its own namespace and anything under
`infra/configs/namespaces/` targets it, add it to `infra/configs-ks.yaml`'s `dependsOn` too.
