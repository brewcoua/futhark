# Network policy

Which templates every namespace composes, what they add up to, and the one path they cannot
govern. Read this when adding a namespace, so its overlay allows exactly what the app needs.

Every non-control-plane namespace gets a default-deny baseline plus explicit opt-in bridges,
assembled per namespace from shared templates in `infra/policies/namespaces/_templates/`:

| Template                             | When                                                                       |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `netpol-default-deny`                | Always                                                                     |
| `netpol-allow-same-namespace`        | Always                                                                     |
| `netpol-allow-from-monitoring`       | Always, except in `monitoring` itself                                      |
| `netpol-allow-from-ingress-internal` | Only if the namespace ships an `Ingress` with `ingressClassName: internal` |
| `netpol-allow-from-ingress-edge`     | Only if the namespace ships an `Ingress` with `ingressClassName: edge`     |

What that composes to, for one namespace: a wall with named holes in it, and one path that goes
around the wall entirely. Each edge is labelled with the template that opens it, minus the
`netpol-` prefix every template name carries. Red is the traffic the baseline drops. The
`ingress-edge` bridge is the loose one: `traefik-edge` runs on `hostNetwork`, so the rule that
admits it matches the mesh CIDR rather than a pod identity.

```d2
direction: down

classes: {
  denied: {
    style: {
      stroke: firebrick
      stroke-dash: 4
    }
  }
  note: {
    style: {
      stroke: dimgray
      stroke-dash: 4
      fill: transparent
    }
  }
  noteline: {
    style: {
      stroke: dimgray
      stroke-dash: 4
    }
  }
}

ns: "any namespace" {
  label.near: outside-top-left
  pods: its pods
}

same: pods in the\nsame namespace
mon: monitoring\n(scrape)
int: "ingress-internal\n(traefik-internal, hostNetwork)"
edge: "ingress-edge\n(traefik-edge, hostNetwork)"
other: everything else { style.stroke-dash: 3 }

same -> ns.pods: allow-same-namespace
mon -> ns.pods: allow-from-monitoring
int -> ns.pods: allow-from-ingress-internal
edge -> ns.pods: allow-from-ingress-edge
other -> ns.pods: "default-deny" {
  class: denied
  target-arrowhead.shape: cf-many
}

ns.pods -> anywhere: egress is never denied

firewalld: "firewalld + Traefik rate limiting\nCNI policy never sees either Traefik's sockets" { class: note }
firewalld -> edge { class: noteline }
firewalld -> int { class: noteline }
```

Kubernetes has no cluster-wide `NetworkPolicy`, so this is one overlay per namespace rather than
one file. Egress is left open everywhere: the secret operators call out to their APIs,
cert-manager calls ACME, and apps call whatever they call. In a single-tenant homelab the risk
that matters is inbound.

One thing the baseline cannot cover: both Traefiks run with `hostNetwork: true`, so each shares
the node's network namespace and CNI policy enforcement never sees its sockets. The
`ingress-edge` and `ingress-internal` overlays exist and are correct, but they do not govern that
traffic. What actually governs it is firewalld (`ansible/roles/firewall_ingress`, public zone
limited to 443 and the hardened SSH port), the fact that the internal ingress binds a mesh address
only peers can reach, and Traefik's own rate limiting.

The same `hostNetwork` is why both `netpol-allow-from-ingress-edge` and
`netpol-allow-from-ingress-internal` are an `ipBlock` and not a `namespaceSelector`: those
connections arrive as the ingress node's own address, so a selector rule never matches and every
request through that ingress returns 502. The block is the whole mesh CIDR from
`ansible/inventory/group_vars/all/network.yml`, not the node's `/32`. `ipBlock` accepts only a
literal, and a `/32` meant substituting an address that had to be maintained by hand in a second
place. The rules therefore trust every mesh peer, not only the ingress; what bounds that is the
NetBird policy in `tofu/netbird`, which decides which peers reach the cluster at all.

The two templates now hold the same rule, and stay separate anyway. They are two decisions that
happen to agree: which one a namespace composes still records which ingress it expects traffic
from, and either can change without dragging the other with it.

## Pod-to-pod across namespaces

The templates above cover the two directions that recur: monitoring scraping everything, and an
ingress reaching one namespace. A pod in one namespace calling a pod in another is neither, and
`monitoring` is the only namespace with such a caller today.

`infra/policies/namespaces/monitoring/netpol-allow-from-glance.yaml` admits Glance to vmsingle on
8428, because every widget on Glance's cluster and network pages is an API query against it, and
Glance is an ordinary pod that no mesh `ipBlock` covers. It is a file in that overlay rather than a
template in `_templates/`: it names one namespace and one port, and a second caller should get its
own file rather than a selector wide enough to hide who reads the metrics store.

The alternative was to point Glance at `metrics.$SUB_INTERNAL.$DOMAIN`, which needs no policy at
all since the request then arrives from traefik-internal. That routes every widget out to the mesh
interface and back, and leaves the dependency written down nowhere.

## Rate limiting

Every namespace with an `Ingress` also composes the `middleware-ratelimit` template, a Traefik
`Middleware` at `average: 100`, `burst: 200`, per source IP. It is basic DoS protection, not a
precise budget.

Composing the template alone does nothing. Traefik only applies a `Middleware` to routers
that name it, so the `Ingress` must reference it explicitly:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: <namespace>-ratelimit@kubernetescrd
```

Same-namespace reference only. `traefik-edge`'s `kubernetesCRD` provider does not set
`allowCrossNamespace`, unlike `traefik-internal`, so a shared cross-namespace `Middleware` would
not resolve there.

Verify a new namespace's policy the way [Pod to mesh networking](../ansible/networking.md#the-isolating-test)
does: from a pod in another namespace, confirm the connection is refused, then confirm the
intended bridge works.
