# Cluster infrastructure

`infra/` holds one directory per cluster-wide component, each with its own Flux
`Kustomization`. Layout rules are in [Layout and naming](../conventions/layout.md); the order
they come up in is [Startup ordering](../conventions/ordering.md).

| Component            | What it is                                                                                                                                |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `infisical-operator` | Runtime secrets. Two namespace-scoped installs, one per tier, plus the admission policy that confines each. See below                     |
| `external-secrets`   | External Secrets Operator, and only the Bitwarden `ClusterSecretStore`. See below                                                         |
| `edge-ips`           | Not a controller: one SOPS-encrypted Secret holding the edge node's addresses, consumed by `postBuild.substituteFrom`                     |
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
`postBuild.substituteFrom` from the SOPS-encrypted `edge-ips` Secret in `infra/edge-ips/`. That
Kustomization has no `dependsOn` on purpose: a substitution target has to exist before its
consumers reconcile, and `infra-configs` — the obvious home for it — depends on `traefik-edge`.

## Infisical operator

The operator is installed **twice**, once per tier, and that is the isolation mechanism rather
than a deployment detail. Each install sets `scopedRBAC: true` with its own `scopedNamespaces`,
so the chart emits a `Role`/`RoleBinding` per listed namespace and no cluster-wide secrets
`ClusterRole`. A tier's ServiceAccount has no permissions anywhere outside its own list.

- **infra tier** — `infra/infisical-operator/app/helmrelease-infra.yaml`, release namespace
  `infisical-infra`. Owns the `secrets.infisical.com` CRDs (`installCRDs: true`).
- **node tier** — `helmrelease-node-<hostname>.yaml`, release namespace
  `infisical-node-<hostname>`, `installCRDs: false` and `dependsOn` the infra release, because
  two installs racing to own the same CRDs is the documented failure mode.

Each tier's namespace appears first in its own `scopedNamespaces`, and not by accident: that is
what lets the operator read the `InfisicalAuth` and credential Secret it authenticates with.
Both tiers share one Infisical machine identity — the free tier caps identities at five — so
what separates them is RBAC plus the `ValidatingAdmissionPolicy` in `config/`, which pins each
`InfisicalStaticSecret`'s `secretPath` to its namespace's tier. The reasoning, and what still
defeats it, is in [Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced).

### Adding a node tier

1. Add `infra/infisical-operator/app/helmrelease-node-<hostname>.yaml` (copy the kenaz one, swap
   the hostname, list that node's app namespaces in `scopedNamespaces`) and register it in the
   sibling `kustomization.yaml`.
2. Add `infra/infisical-operator/config/nodes/<hostname>.yaml` for the tier's
   `InfisicalConnection` + `InfisicalAuth`, and list it in that `kustomization.yaml`.
3. Add the new namespace to `flux_bootstrap_infisical_namespaces` in
   `ansible/roles/flux_bootstrap/defaults/main.yml`, so the credential gets seeded there.

## External Secrets Operator

ESO's only remaining job is Bitwarden Secrets Manager, which has no operator of its own. It
reads through `bitwarden-sdk-server`, a sidecar the chart deploys because the Bitwarden SDK is
Rust/CGO and too heavy to link into ESO; `infra/external-secrets/config/certificate.yaml` issues
that sidecar's HTTPS certificate from a `SelfSigned` issuer.

The store's `conditions` list is empty, which makes it unusable from every namespace. That is
the intended resting state — see [Secrets](../conventions/secrets.md#bitwarden-secrets-manager).
The RBAC ESO itself runs under is deliberately narrow; same page.
