# Network policy

Every non-control-plane namespace gets a default-deny baseline plus explicit opt-in bridges,
assembled per namespace from shared templates in
`infra/configs/namespaces/_templates/`:

| Template                             | When                                                                       |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `netpol-default-deny`                | Always                                                                     |
| `netpol-allow-same-namespace`        | Always                                                                     |
| `netpol-allow-from-monitoring`       | Always, except in `monitoring` itself                                      |
| `netpol-allow-from-ingress-internal` | Only if the namespace ships an `Ingress` with `ingressClassName: internal` |
| `netpol-allow-from-ingress-edge`     | Only if the namespace ships an `Ingress` with `ingressClassName: edge`     |

Kubernetes has no cluster-wide `NetworkPolicy`, so this is one overlay per namespace rather
than one file. Egress is left open everywhere — the secret operators call out to their APIs,
cert-manager calls ACME,
apps call whatever they call. In a single-tenant homelab the risk that matters is inbound.

One thing the baseline cannot cover: `traefik-edge` runs with `hostNetwork: true`, so it
shares the node's network namespace and CNI policy enforcement never sees its sockets. The
`ingress-edge` overlay exists and is correct, but it does not govern that traffic. What
actually governs it is firewalld (`ansible/roles/firewall_ingress`, public zone limited to
80/443 and the hardened SSH port) and Traefik's own rate limiting.

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
