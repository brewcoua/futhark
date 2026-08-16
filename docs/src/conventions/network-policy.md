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
five callers do it today. Each namespace they reach admits them with its own file. Every one of
these files names the port the pod listens on, not the port its `Service` publishes.

Glance reaches into two namespaces.

`infra/policies/namespaces/monitoring/netpol-allow-from-glance.yaml` admits Glance to vmsingle on
8428 and to vlsingle on 9428, because most widgets on Glance's cluster and network pages are an API
query against one of them, and Glance is an ordinary pod that no mesh `ipBlock` covers.
`infra/policies/namespaces/gatus/netpol-allow-from-glance.yaml` does the same for the Gatus API on
8080, which is where the apps page gets service health.

Open WebUI is the second caller, and reaches into two namespaces.

`infra/policies/namespaces/searxng/netpol-allow-from-open-webui.yaml` admits it to SearXNG on
8080, which is where its web search runs its queries. It could have gone through
`search.$SUB_INTERNAL.$DOMAIN` instead, but that host sits behind `auth-sso` and a pod carries no
session cookie. `infra/policies/namespaces/bifrost/netpol-allow-from-open-webui.yaml` admits it to
Bifrost on 8080, which is its only model backend.

Vane and Local Deep Research are the third and fourth, and each reaches the same two namespaces
Open WebUI does, for the same two reasons: `searxng` on 8080 for results, `bifrost` on 8080 for
the model. That is four more files, named after the caller in each of those two overlays.

Bifrost is the fifth caller.
`infra/policies/namespaces/cli-proxy-api/netpol-allow-from-bifrost.yaml` admits it to
cli-proxy-api on 8317. That file matters more than the others: cli-proxy-api has no `Ingress` and
composes no `netpol-allow-from-ingress-internal`, so with the default deny in place this one hole
is the whole of its reachability. That is what lets its `config.yaml` ship an empty `api-keys`
list instead of carrying a credential of its own.

Each is a file in its own overlay rather than a template in `_templates/`: each names one
namespace, and a further caller should get its own file rather than a selector wide enough to
hide who reads what.

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
