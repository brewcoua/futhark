# Network policy

Every non-control-plane namespace gets a default-deny baseline plus explicit opt-in bridges,
assembled per namespace from shared templates in
`infra/policies/namespaces/_templates/`:

| Template                             | When                                                                       |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `netpol-default-deny`                | Always                                                                     |
| `netpol-allow-same-namespace`        | Always                                                                     |
| `netpol-allow-from-monitoring`       | Always, except in `monitoring` itself                                      |
| `netpol-allow-from-ingress-internal` | Only if the namespace ships an `Ingress` with `ingressClassName: internal` |
| `netpol-allow-from-ingress-edge`     | Only if the namespace ships an `Ingress` with `ingressClassName: edge`     |

What that composes to, for one namespace — a wall with named holes in it, and one path that
goes around the wall entirely:

```d2
direction: down

ns: "any namespace" {
  pods: its pods
}

same: pods in the\nsame namespace
mon: monitoring\n(scrape)
int: "ingress-internal\n(traefik-internal)"
edge: "ingress-edge\n(traefik-edge, hostNetwork)"
other: everything else { style.stroke-dash: 3 }

same -> ns.pods: netpol-allow-same-namespace
mon -> ns.pods: netpol-allow-from-monitoring
int -> ns.pods: netpol-allow-from-ingress-internal
edge -> ns.pods: "netpol-allow-from-ingress-edge\nmatches the mesh CIDR, not a pod identity"
other -> ns.pods: "netpol-default-deny" {
  style: { stroke-dash: 4; stroke: "#888" }
  target-arrowhead.shape: cf-many
}

ns.pods -> anywhere: egress is never denied

firewalld: "firewalld + Traefik rate limiting\nCNI policy never sees traefik-edge's sockets" {
  style: { stroke-dash: 4; fill: transparent }
}
firewalld -> edge: { style.stroke-dash: 4 }
```

Kubernetes has no cluster-wide `NetworkPolicy`, so this is one overlay per namespace rather
than one file. Egress is left open everywhere — the secret operators call out to their APIs,
cert-manager calls ACME,
apps call whatever they call. In a single-tenant homelab the risk that matters is inbound.

One thing the baseline cannot cover: `traefik-edge` runs with `hostNetwork: true`, so it
shares the node's network namespace and CNI policy enforcement never sees its sockets. The
`ingress-edge` overlay exists and is correct, but it does not govern that traffic. What
actually governs it is firewalld (`ansible/roles/firewall_ingress`, public zone limited to
80/443 and the hardened SSH port) and Traefik's own rate limiting.

The same `hostNetwork` is why `netpol-allow-from-ingress-edge` is an `ipBlock` and not a
`namespaceSelector`: those connections arrive as the edge node's own address, so a selector rule
never matches and every request through the public edge returns 502. The block is the whole mesh
CIDR from `ansible/inventory/group_vars/all/network.yml`, not the edge node's `/32`. `ipBlock`
accepts only a literal, and a `/32` meant substituting an address that had to be maintained by hand
in a second place. The rule therefore trusts every mesh peer, not only the edge; what bounds that
is the NetBird policy in `tofu/netbird`, which decides which peers reach the cluster at all.

## Rate limiting

Every namespace with an `Ingress` also composes the `middleware-ratelimit` template — a
Traefik `Middleware` at `average: 100`, `burst: 200`, per source IP. It is basic DoS
protection, not a precise budget.

Composing the template alone does nothing. Traefik only applies a `Middleware` to routers
that name it, so the `Ingress` must reference it explicitly:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: <namespace>-ratelimit@kubernetescrd
```

Same-namespace reference only. `traefik-edge`'s `kubernetesCRD` provider does not set
`allowCrossNamespace` (unlike `traefik-internal`), so a shared cross-namespace `Middleware`
would not resolve there.
