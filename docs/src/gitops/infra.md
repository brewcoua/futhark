# Cluster infrastructure

What each cluster-wide component is, and the four that behave unlike the rest: the two ingresses,
monitoring, and the per-tier Infisical operator. Layout rules are in
[Layout and naming](../conventions/layout.md), and the order they come up in is
[Startup ordering](../conventions/ordering.md).

`infra/` holds one directory per component, each with its own Flux `Kustomization`.

| Component            | What it is                                                                                                                                                       |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infisical-operator` | Runtime secrets. One namespace-scoped install per tier, plus the admission policy that confines each. See below                                                  |
| `substitutions`      | Not a controller: every `postBuild.substituteFrom` source, meaning the `cluster-values` Secret and `monitoring-sizing`                                           |
| `auth`               | Pocket ID, the OIDC provider, plus the oauth2-proxy that fronts apps which cannot speak OIDC. See below                                                          |
| `cert-manager`       | Let's Encrypt certificates over DNS-01, through a Bunny DNS webhook. `config/` holds the `ClusterIssuer`                                                         |
| `traefik-internal`   | Mesh-only ingress, serving the internal wildcard cert. `hostNetwork: true`, bound to the ingress node's mesh address                                             |
| `traefik-edge`       | Public ingress. `hostNetwork: true`, bound to the ingress node's public address                                                                                  |
| `storage`            | `csi-driver-rclone` and two zero-knowledge StorageClasses: `storagebox-crypt` (offsite box, crypt over sftp) and `gdrive-crypt` (Google Drive, write-once media) |
| `backup`             | K8up, and the nightly schedules that carry the `local-path` volumes to Backblaze B2 as restic snapshots. See [Backup and recovery](../operations/recovery.md)    |
| `monitoring`         | VictoriaMetrics, VictoriaLogs, Grafana, exporters. One `app/` subdirectory per workload, see below                                                               |
| `namespaces`         | Not a controller: every `Namespace` CR in the cluster, in one Kustomization that depends on nothing                                                              |
| `policies`           | Not a controller: the network policy, RBAC and rate-limit overlays every namespace composes                                                                      |
| `glance`             | The dashboard at `home.$SUB_INTERNAL.$DOMAIN`. Two Kustomizations, one of which must not be substituted. See below                                               |

## The two ingresses

Two releases, not one, because they answer on different addresses under different trust
assumptions. Both run `hostNetwork: true` on the same node, and that is why they are the odd ones
out everywhere else in the tree. There is no LoadBalancer to hand either a Service address.
MetalLB was considered and rejected, since it can only manage a real L2 or BGP-announced IP, not a
mesh one.

`traefik-internal` binds 443 on `${MESH_IP}`, the ingress node's mesh address. Give an internal
`Ingress` the class `internal`. It never carries its own `tls:` block, because the wildcard is
served as the default certificate. It has no Service at all, and [`tofu/netbird`](../tofu/netbird.md)
points the internal wildcard record straight at that address. A peer address needs no route, which
is the whole reason for the shape: the mesh reaches it natively.

It used to be a pinned `ClusterIP` reached over a NetBird route that advertised the entire service
CIDR. That path failed silently, with the route reporting `Selected` on the client and no packet
ever crossing, and it cost a routing peer, `masquerade`, and a pinned address that had to stay
inside `k8s_service_cidr`. None of that exists now.

`traefik-edge` binds 443 on `${PUBLIC_IP}`, and its dashboard and metrics entryPoints on
`${MESH_IP}`, so those stay off the public interface. It cannot bind 80: the ingress node's
`net.ipv4.ip_unprivileged_port_start` is lowered only as far as 443
(`ansible/roles/firewall_ingress`), and neither release binds a plaintext port. `traefik-internal`
takes 8082 for its ping entryPoint because `traefik-edge` already holds 8081 on the mesh address.
They share one network namespace, so every port either one binds is a port the other cannot.

`hostNetwork` means CNI `NetworkPolicy` enforcement never sees either release's sockets, so
neither the `ingress-edge` nor the `ingress-internal` baseline governs that traffic. What governs
it is firewalld, the fact that the mesh address is only reachable from the mesh, and Traefik's own
rate limiting. It is also why both `netpol-allow-from-ingress-*` templates are an `ipBlock` and
not a `namespaceSelector`. See [Network policy](../conventions/network-policy.md).

Both addresses are substituted by `postBuild.substituteFrom` from the SOPS-encrypted
`cluster-values` Secret in `config/sops/`. That Kustomization has no `dependsOn` on purpose: a
substitution target has to exist before its consumers reconcile, and `infra-policies`, the obvious
home for it, depends on `traefik-edge`.

These two releases are the Secret's only consumers of those keys, and the reason they have to be:
`hostIP` in a pod spec takes no `fieldRef`, so an address bound there has to be written down.
Where the same address is needed as data rather than as a bind target, it is discovered instead.
Both Traefik scrape jobs in `infra/monitoring` read it off the API server, since a `hostNetwork`
pod's `status.podIP` is the kubelet's `node-ip`, which `config.yaml.j2` sets to the mesh address.

## Auth

Two Deployments in one namespace, doing two different jobs.

**Pocket ID** is the OIDC provider, edge-exposed at `auth.$DOMAIN` because it is the login page for
everything. It is pinned to `ogma` on single-writer SQLite, so its Deployment uses
`strategy: Recreate` and never runs two pods at once. Apps that speak OIDC talk to it directly and
need nothing else.

**oauth2-proxy** exists for the apps that do not. It is a single relying party registered as one
Pocket ID client, exposed internally at `sso.$SUB_INTERNAL.$DOMAIN`, and it publishes the Traefik
`Middleware` `auth-sso@kubernetescrd`. Any internal Ingress that names that middleware gets a
login. See
[Internal ingresses are unauthenticated by default](../conventions/domains.md#internal-ingresses-are-unauthenticated-by-default)
for how to opt an app in.

Three settings in `app/oauth2-proxy-configmap.yaml` carry the design, and changing any of them
changes what the reader sees:

- `OAUTH2_PROXY_UPSTREAMS: static://202` with `OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"` is
  oauth2-proxy's documented Traefik static-upstream setup. The middleware calls the proxy's root
  path, which answers `202` on a valid session and `302` to Pocket ID otherwise. Because the
  provider button is skipped, no oauth2-proxy-branded page is ever rendered: the only login UI is
  Pocket ID's own.
- `OAUTH2_PROXY_COOKIE_DOMAINS: .$SUB_INTERNAL.$DOMAIN` is what makes one login cover every
  protected host. `OAUTH2_PROXY_WHITELIST_DOMAINS` has to match, since it bounds where the
  post-login redirect may send the browser.
- `OAUTH2_PROXY_COOKIE_NAME` uses the `__Secure-` prefix, not `__Host-`. The `__Host-` prefix
  forbids a `Domain` attribute, and a `Domain` attribute is exactly what shares the session across
  subdomains.

The gate is binary. `OAUTH2_PROXY_ALLOWED_GROUPS` admits `administrators` and `users`, and the app
behind the middleware learns nothing about which one the reader is in. An app that needs roles has
to speak OIDC itself.

Three secrets at `/infra/auth` feed it. `SSO_OIDC_CLIENT_ID` and `SSO_OIDC_CLIENT_SECRET` are
minted by `tofu/oidc` (see [oidc](../tofu/oidc.md)). `SSO_COOKIE_SECRET` is seeded by hand, once:

```bash
openssl rand -base64 32 | tr -- '+/' '-_'
```

Store that in Infisical at `/infra/auth` before the Deployment first reconciles. Without it the
`InfisicalStaticSecret` template renders an empty value and oauth2-proxy refuses to start.

## Monitoring

One Flux `Kustomization`, four workloads, one directory each under `infra/monitoring/app/`:
`metrics/` (vmsingle + vmagent), `logs/` (vlsingle + vlagent), `exporters/` and `grafana/`.
Only `helmrepositories.yaml` stays flat, since every one of them draws on it.

**Alert rules are in `grafana/alerting/`**, one file per group (`watchdog.yaml`,
`node-health.yaml`, `kubernetes.yaml`, `mesh.yaml`, `backup.yaml`) plus `contactpoints.yaml` and
`policies.yaml`. They are ordinary Grafana provisioning YAML: write `{{ $labels.instance }}` as
you would in the UI. Nothing escapes it, because nothing templates it. `kustomization.yaml`
generates them into one ConfigMap labelled `grafana_alert: "1"`, and the chart's alerts sidecar
copies it into `/etc/grafana/provisioning/alerting/` and POSTs Grafana's reload endpoint, so an
edit lands on the next reconcile without restarting Grafana.

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
to match the rule, because Alertmanager flushes on `group_interval` ticks and requires
`repeat_interval` to be at least as long.

**Dashboards are in `grafana/dashboards/`**, one JSON file each, generated into one ConfigMap
per dashboard labelled `grafana_dashboard: "1"` and annotated `grafana_folder` with the Grafana
folder to file it under. The chart's dashboards sidecar writes each into
`/var/lib/grafana/dashboards/<folder>/`, and `foldersFromFilesStructure` turns that directory back
into the folder name. `allowUiUpdates: false`, so Grafana refuses a UI edit rather than accepting
one the next sync would overwrite.

They are reconciled by their own Flux `Kustomization`, `infra/monitoring/dashboards-ks.yaml`,
whose only distinguishing feature is that it has no `postBuild`. Dashboard JSON is full of
Grafana's own `${namespace}`-style interpolations. `postBuild` substitution would blank the ones
it reads as undefined cluster variables, and on `${__field.labels.node}` it does not get that
far: the build fails with `envsubst error: variable substitution failed: missing closing brace`.
Do not fold this directory back into the `monitoring` Kustomization, and do not escape the JSON
to make that possible.

Adding a dashboard is three steps: drop the JSON in `grafana/dashboards/`, add a
`configMapGenerator` entry for it, and point `grafana_folder` at a folder. Pin the datasource by
its provisioned uid (`victoriametrics` or `victorialogs`) instead of shipping a `datasource`
template variable, so a dashboard cannot be pointed at the wrong store by a stray dropdown.

`vmagent`'s scrape targets are in `metrics/scrape-configs.yaml`, merged into the release with
`valuesFrom` rather than kept inline, so adding a target does not mean editing a `HelmRelease`.
One file, not one per job: Flux merges `valuesFrom` entries with arrays replaced, so two
ConfigMaps each holding `scrape_configs` would silently clobber each other.

The `cadvisor` and `kubelet` jobs scrape each node's kubelet directly on port 10250, not through
the API server's `/api/v1/nodes/<node>/proxy/` path. The proxy path authorizes against
`nodes/proxy`, which the vmagent chart's `ClusterRole` does not grant, so it answered `403` and
collected no `container_*` metrics at all. A direct scrape authorizes against `nodes/metrics`,
which the chart does grant. Both jobs relabel `node` and `instance` from the discovered node
name, because cadvisor carries neither and the dashboards select on `node`. The `kubelet` job
keeps only `kubelet_volume_stats_*`; the full endpoint is around 76,000 samples per node per
scrape.

`config.global.external_labels` stamps `cluster` on every series. It exists because the
Kubernetes dashboards select `cluster="$cluster"` on every query and nothing else here emits that
label.

Retention and volume size for both stores are in
`infra/substitutions/app/monitoring-sizing.yaml`, reaching the releases as `${VM_RETENTION}` and
friends. They sit together because they are one decision against one local-path disk. CPU and
memory are not there. Those are per-workload and stay next to the release that sets them.
The file cannot live under `infra/monitoring/`: a `substituteFrom` source has to exist before its
consumer reconciles.

## Host logs

The `vlagent` DaemonSet collects container logs, and one file from the host itself:
`/var/log/fail2ban.log`, declared as a `fileCollector` glob in
`infra/monitoring/app/logs/vlagent.yaml`. It works with no shipper on the node and no route from the
host into the cluster, because the chart already mounts each node's `/var/log` read-only.

Query the bans in Grafana against the `VictoriaLogs` datasource as `app:fail2ban`. vlagent
attaches `hostname` and `file` on its own, so events stay attributable per node.

The other half, the jails and why fail2ban logs to a file at all, is in
[Inventory and roles](../ansible/index.md#fail2ban).

## Glance

The dashboard at `home.$SUB_INTERNAL.$DOMAIN`, behind `auth-sso@kubernetescrd`. Four pages: home,
apps, cluster, network. It holds no state, so there is no PVC and no K8up `Schedule` entry: the
widget cache is in memory and the todo widget's items are in the reader's browser.

It is two Flux `Kustomization`s, and the split is the one thing to understand before editing it.

`glance` reconciles `app/` with `postBuild` substitution, the way every other component does.
`glance-config` reconciles `config/` **without** it, for the same reason
`infra/monitoring/dashboards-ks.yaml` does: Glance's own environment variable syntax is
`${VAR}`, byte for byte what Flux's envsubst consumes, and every API token and hostname in those
files is one. Under substitution they would all be read as unset cluster variables.

So the values reach Glance as real environment variables instead. `app/deployment.yaml` is in the
substituted Kustomization and spells `${SUB_INTERNAL}` and `${DOMAIN}` there once; the config files
read them back at runtime. The API tokens arrive the same way, from the `glance-secrets` Secret.

Three consequences worth knowing before a config edit fails in an unhelpful way:

- Glance exits on a variable that does not resolve. A new `${SOMETHING}` in a config file means
  adding `SOMETHING` to Infisical at `/infra/glance` first, or the pod crash-loops.
- Substitution runs over comments too. Writing the literal string `${VAR}` in a YAML comment is
  enough to fail startup with `parsing variable: environment variable VAR not found`.
- An `$include`d page file must open with its own list marker (`- name: Home`) and indent the rest
  under it. Glance splices the file at the `$include` line and drops the `-` that was there, so a
  page file written as a bare mapping silently merges into the page before it.

Validate a config change without a cluster:

```bash
podman run --rm \
  -e SUB_INTERNAL=in -e DOMAIN=example.eu \
  -e NASA_API_KEY=x -e WAQI_TOKEN=x -e GITHUB_TOKEN=x -e NETBIRD_API_KEY=x \
  -v ./infra/glance/config:/app/config:ro,Z \
  docker.io/glanceapp/glance:v0.8.5 config:validate
```

Exit status 0 means the YAML parses and every widget's options are valid. It does not fetch
anything, so a broken PromQL query or a wrong metric label still only shows up in the browser.

Every widget on the cluster and network pages is a `custom-api` query against vmsingle over the
cluster network, which is what `infra/policies/namespaces/monitoring/netpol-allow-from-glance.yaml`
opens. Two of them need scrape jobs that exist only for them: `flux` for
`gotk_reconcile_condition`, and `cert-manager` for
`certmanager_certificate_expiration_timestamp_seconds`. Both are in
`infra/monitoring/app/metrics/scrape-configs.yaml`.

The backups widget shows job outcomes and nothing else. K8up's per-repository gauges, including
`k8up_backup_restic_available_snapshots`, are only ever pushed to a Prometheus Pushgateway by the
backup job itself, and there is no Pushgateway here. Ask the repository directly with
`just bak snapshots`.

## Infisical operator

The operator is installed **once per tier**, and that is the isolation mechanism rather than a
deployment detail. Each install sets `scopedRBAC: true` with its own `scopedNamespaces`, so the
chart emits a `Role`/`RoleBinding` per listed namespace and no cluster-wide secrets
`ClusterRole`. A tier's ServiceAccount has no permissions anywhere outside its own list.

- **infra tier**: `infra/infisical-operator/app/helmrelease-infra.yaml`, release namespace
  `infisical-infra`. Owns the `secrets.infisical.com` CRDs (`installCRDs: true`).
- **node tier**: `helmrelease-node-<hostname>.yaml`, release namespace
  `infisical-node-<hostname>`, `installCRDs: false` and `dependsOn` the infra release, because
  two installs racing to own the same CRDs is the documented failure mode.
- **backup tier**: `helmrelease-backup.yaml`, release namespace `infisical-backup`, scoped to
  itself and `k8up`. Not per-host, and the only tier with a machine identity of its own.

Each tier's namespace appears first in its own `scopedNamespaces`, and not by accident: that is
what lets the operator read the `InfisicalAuth` and credential Secret it authenticates with.
The infra and node tiers share one Infisical machine identity, because the free tier caps
identities at five, so what separates _them_ is RBAC plus the `ValidatingAdmissionPolicy` in
`config/`, which pins each `InfisicalStaticSecret`'s `secretPath` to its namespace's tier. The backup tier goes
further and authenticates as a second identity, because the admission policy alone would let any
infra namespace read `/infra/k8up` and that is the password that decrypts every backup. The
reasoning, and what still defeats it, is in
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced).

### Adding a node tier

1. Add `infra/namespaces/app/namespaces.yaml` entries for the tier's own namespace and that
   node's app namespaces. The chart's scoped `Role`s are written into namespaces it does not
   create, so the install fails outright if any of them is missing.
2. Add `infra/infisical-operator/app/helmrelease-node-<hostname>.yaml`, copying the kenaz one,
   swapping the hostname and listing those app namespaces in `scopedNamespaces`, then register it
   in the sibling `kustomization.yaml`.
3. Add `infra/infisical-operator/config/nodes/<hostname>.yaml` for the tier's
   `InfisicalConnection` and `InfisicalAuth`, and list it in that `kustomization.yaml`.
4. Copy `infra/policies/namespaces/infisical-node-kenaz/` to the new tier's namespace and
   register it in `infra/policies/kustomization.yaml`. The tier namespace holds that tier's copy
   of the universal-auth credential, so it is the last place to leave without a baseline.
5. Set `app_tier: true` in `ansible/nodes/<hostname>/host.yml`, so `flux_bootstrap` seeds the
   credential into the new namespace. The list of tiers is derived from that flag rather than
   written out, so there is nothing to keep in step with step 1.

Verify: after `just ans k8s` and a push, `just fx failing` is empty and
`kubectl -n infisical-node-<hostname> get infisicalauth` reports ready.
