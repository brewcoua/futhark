# Cluster infrastructure

`infra/` holds one directory per cluster-wide component, each with its own Flux
`Kustomization`. Layout rules are in [Layout and naming](../conventions/layout.md); the order
they come up in is [Startup ordering](../conventions/ordering.md).

| Component            | What it is                                                                                                                                |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `openbao`            | Secret store. Single-replica StatefulSet pinned to `ogma`, raft on a local-path volume, auto-unsealed by an external KMIP service. Not HA |
| `external-secrets`   | External Secrets Operator plus the `ClusterSecretStore`s pointing at OpenBao. See below                                                   |
| `auth`               | Pocket ID, the OIDC provider. Pinned to `ogma`, single-writer SQLite so its Deployment uses `strategy: Recreate` — never two pods at once |
| `cert-manager`       | Let's Encrypt certificates over DNS-01, through a Bunny DNS webhook. `config/` holds the `ClusterIssuer`                                  |
| `tailscale-operator` | Gives Services their own tailnet identity via `type: LoadBalancer` + `loadBalancerClass: tailscale`                                       |
| `traefik-internal`   | Mesh-only ingress, serving the internal wildcard cert. Exposed through the Tailscale operator                                             |
| `traefik-edge`       | Public ingress. `hostNetwork: true`, bound to the edge node's own addresses                                                               |
| `storage`            | `csi-driver-rclone` and the `storagebox-crypt` StorageClass — an offsite box over rclone crypt→sftp, zero-knowledge                       |
| `monitoring`         | VictoriaMetrics, VictoriaLogs, Grafana, Headlamp, exporters                                                                               |
| `configs`            | Not a controller: the namespaces, network policy, RBAC and rate-limit overlays every other namespace composes                             |

## The two ingresses

They are split because they solve different problems, and the split is why `traefik-edge` is
the odd one out everywhere else in the tree.

`traefik-internal` is exposed through the Tailscale operator, so the Service gets its own
tailnet identity. Ordinary `NetworkPolicy` still governs its traffic and there is no node IP
to know or inject anywhere. Give an internal `Ingress` the class `internal`; it never carries
its own `tls:` block, because the wildcard is served as the default certificate.

`traefik-edge` binds 80/443 directly on the edge node with `hostNetwork: true`. There is no
LoadBalancer to hand it a Service address — MetalLB was considered and rejected, since it can
only manage a real L2/BGP-announced IP, not a tailnet one. `hostNetwork` means it shares the
node's network namespace, so CNI `NetworkPolicy` enforcement never sees its sockets and the
`ingress-edge` baseline cannot govern it. What actually governs it is firewalld
(`ansible/roles/firewall_ingress`) and Traefik's own rate limiting. See
[Network policy](../conventions/network-policy.md).

The addresses it binds are `${PUBLIC_IP}` and `${MESH_IP}`, substituted by
`postBuild.substituteFrom` from the `edge-ips` ConfigMap that `ansible/roles/flux_bootstrap`
pushes into the cluster.

## External Secrets Operator

ESO is pointed at `infra/openbao` through its `vault` provider, reached in-cluster at
`openbao.openbao.svc.cluster.local:8200`. Isolation is enforced by OpenBao **namespaces**, not
path-prefix policies: each namespace has its own `secret/` kv-v2 mount, its own `kubernetes`
auth mount and its own `reader` policy, so a compromised binding cannot read outside its own
namespace by construction.

- **`infra` namespace** — `infra/external-secrets/config/clustersecretstore-infra.yaml`, store `bao-infra`. Used by
  every node-agnostic component: `cert-manager`, `storage`, `monitoring` and the rest.
- **`node-<hostname>` namespace** — `infra/external-secrets/config/nodes/<hostname>.yaml`, one per k0s node, store
  `bao-node-<hostname>`. Used by that node's own apps under `nodes/<hostname>.k0s/`.

Every `ClusterSecretStore` authenticates via OpenBao's `kubernetes` auth method as the
`external-secrets` ServiceAccount in the `external-secrets` namespace, so no long-lived
credential lives in-cluster at all — the k0s API validates each request with a TokenReview. An
app needing secrets from both scopes uses two `ExternalSecret`s, one per `secretStoreRef`; a
store's reach is never widened to cover both.

Namespace, mount and auth-role bootstrap is `ansible/roles/openbao`'s `tasks/namespaces.yml`,
run by `task bao:policy-sync` against the in-cluster OpenBao over `kubectl exec`. It is not
managed by tofu — this repo has no OpenBao provider outside the one write exception described
in [Rules for every module](../tofu/index.md).

The RBAC ESO itself runs under is deliberately narrow; see
[Secrets](../conventions/secrets.md).

### Adding a node to ESO

1. `task bao:policy-sync` — it loops every `nodes/*.k0s/` directory and bootstraps any
   `node-<hostname>` namespace that does not exist yet.
2. Add `infra/external-secrets/config/nodes/<hostname>.yaml` (copy `kenaz.yaml`, swap the
   hostname) and list it in the sibling `kustomization.yaml`.
