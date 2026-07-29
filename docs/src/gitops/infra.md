# Cluster infrastructure

`infra/` holds one directory per cluster-wide component, each with its own Flux
`Kustomization`. Layout rules are in [Layout and naming](../conventions/layout.md); the order
they come up in is [Startup ordering](../conventions/ordering.md).

| Component            | What it is                                                                                                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infisical-operator` | Runtime secrets. Two namespace-scoped installs, one per tier, plus the admission policy that confines each. See below                                                     |
| `substitutions`      | Not a controller: every `postBuild.substituteFrom` source — the `edge-ips` and `int-domain` Secrets, `monitoring-sizing`, and `${DOMAIN}` from `config/domain/domain.env` |
| `auth`               | Pocket ID, the OIDC provider. Pinned to `ogma`, single-writer SQLite so its Deployment uses `strategy: Recreate` — never two pods at once                                 |
| `cert-manager`       | Let's Encrypt certificates over DNS-01, through a Bunny DNS webhook. `config/` holds the `ClusterIssuer`                                                                  |
| `tailscale-operator` | Gives Services their own tailnet identity via `type: LoadBalancer` + `loadBalancerClass: tailscale`                                                                       |
| `traefik-internal`   | Mesh-only ingress, serving the internal wildcard cert. Exposed through the Tailscale operator                                                                             |
| `traefik-edge`       | Public ingress. `hostNetwork: true`, bound to the edge node's own addresses                                                                                               |
| `storage`            | `csi-driver-rclone` and the `storagebox-crypt` StorageClass — an offsite box over rclone crypt→sftp, zero-knowledge                                                       |
| `monitoring`         | VictoriaMetrics, VictoriaLogs, Grafana, Headlamp, exporters. One `app/` subdirectory per workload — see below                                                             |
| `namespaces`         | Not a controller: every `Namespace` CR in the cluster, in one Kustomization that depends on nothing                                                                       |
| `policies`           | Not a controller: the network policy, RBAC and rate-limit overlays every namespace composes                                                                               |

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
`postBuild.substituteFrom` from the SOPS-encrypted `edge-ips` Secret in `infra/substitutions/`.
That Kustomization has no `dependsOn` on purpose: a substitution target has to exist before its
consumers reconcile, and `infra-policies` — the obvious home for it — depends on `traefik-edge`.

## Monitoring

One Flux `Kustomization`, five workloads, one directory each under `infra/monitoring/app/`:
`metrics/` (vmsingle + vmagent), `logs/` (vlsingle + vlagent), `exporters/`, `grafana/` and
`headlamp/`. Only `helmrepositories.yaml` stays flat, since every one of them draws on it.

**Alert rules are in `grafana/alerting/`**, one file per group — `watchdog.yaml`,
`node-health.yaml`, `kubernetes.yaml` — plus `contactpoints.yaml` and `policies.yaml`. They are
ordinary Grafana provisioning YAML: write `{{ $labels.instance }}` as you would in the UI. Nothing
escapes it, because nothing templates it. `kustomization.yaml` generates them into one ConfigMap
labelled `grafana_alert: "1"`, and the chart's alerts sidecar copies it into
`/etc/grafana/provisioning/alerting/` and POSTs Grafana's reload endpoint — so an edit lands on
the next reconcile without restarting Grafana.

They used to live in the `HelmRelease` values, where the chart ran the whole block through Helm's
`tpl` and every `{{ $labels.x }}` had to be written `{{ "{{" }} $labels.x {{ "}}" }}` to survive
it. If you ever put alerting back into `values`, that escaping comes back with it.

The sidecar is also why the release sets `rbac.namespaced: true` with an explicit
`extraRoleRules`. The chart's default hands it configmap and secret read across the whole
cluster, and the chart's own `Role` omits the rule for the alerts sidecar specifically.

The one thing that still needs the double-`$` form is `$${SLACK_WEBHOOK_URL}` in
`contactpoints.yaml`. That guards against Flux, not Helm: `postBuild` substitution runs over the
generated ConfigMap and would blank an undefined `${VAR}`. `$$` escapes it to the literal that
Grafana's own env expansion then reads, out of the secret named in
[Secrets](../conventions/secrets.md).

`watchdog.yaml` is the dead-man's switch, and it sets its own `group_wait`, `group_interval` and
`repeat_interval` for a reason. A rule's `interval` only decides how often the alert is
_evaluated_; how often a still-firing alert re-notifies is policy-side, and the inherited
defaults (5m and 4h) mean the healthchecks.io ping lands about every four hours. Both go to `1m`
to match the rule — Alertmanager flushes on `group_interval` ticks and requires
`repeat_interval` to be at least as long.

`vmagent`'s scrape targets are in `metrics/scrape-configs.yaml`, merged into the release with
`valuesFrom` rather than kept inline — adding a target shouldn't mean editing a `HelmRelease`.
One file, not one per job: Flux merges `valuesFrom` entries with arrays replaced, so two
ConfigMaps each holding `scrape_configs` would silently clobber each other.

Retention and volume size for both stores are in
`infra/substitutions/app/monitoring-sizing.yaml`, reaching the releases as `${VM_RETENTION}` and
friends. They sit together because they are one decision against one local-path disk. CPU and
memory are not there — those are per-workload and stay next to the release that sets them.
The file cannot live under `infra/monitoring/`: a `substituteFrom` source has to exist before its
consumer reconciles.

## Host logs

The `vlagent` DaemonSet collects container logs, and one file from the host itself:
`/var/log/fail2ban.log`, declared as a `fileCollector` glob in
`infra/monitoring/app/logs/vlagent.yaml`. It works with no shipper on the node and no route from the
host into the cluster, because the chart already mounts each node's `/var/log` read-only.

Query the bans in Grafana against the `VictoriaLogs` datasource as `app:fail2ban`. vlagent
attaches `hostname` and `file` on its own, so events stay attributable per node.

The other half — the jails, and why fail2ban logs to a file at all — is in
[Inventory and roles](../ansible/index.md#fail2ban).

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

1. Add `infra/namespaces/app/namespaces.yaml` entries for the tier's own namespace and that
   node's app namespaces — the chart's scoped `Role`s are written into namespaces it does not
   create, so the install fails outright if any of them is missing.
2. Add `infra/infisical-operator/app/helmrelease-node-<hostname>.yaml` (copy the kenaz one, swap
   the hostname, list those app namespaces in `scopedNamespaces`) and register it in the
   sibling `kustomization.yaml`.
3. Add `infra/infisical-operator/config/nodes/<hostname>.yaml` for the tier's
   `InfisicalConnection` + `InfisicalAuth`, and list it in that `kustomization.yaml`.
4. Copy `infra/policies/namespaces/infisical-node-kenaz/` to the new tier's namespace and
   register it in `infra/policies/kustomization.yaml`. The tier namespace holds that tier's copy
   of the universal-auth credential, so it is the last place to leave without a baseline.
5. Set `app_tier: true` in `ansible/nodes/<hostname>/host.yml`, so `flux_bootstrap` seeds the
   credential into the new namespace. The list of tiers is derived from that flag rather than
   written out, so there is nothing to keep in step with step 1.
