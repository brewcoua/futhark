# Nodes

One `ansible/nodes/<hostname>/host.yml` per node — the source of truth for that host.
`ansible/inventory/host_vars/<hostname>.yml` is a symlink to it, which is how Ansible picks it
up.

Do not confuse `ansible/nodes/` with the repo-root `nodes/`. This one is provisioning data:
identity, address, how to reach and bootstrap the host. The other is workload definition —
what runs once the host exists. See [Node apps](../gitops/nodes.md).

## Schema

```yaml
node:
  hostname: kenaz
  os: fedora
  workflow: k0s
  k0s_role: controller+worker
  mesh: true
  public_ingress: true
  ip: "{{ lookup('protonpass', 'pass://futharkd/kenaz/ip address') }}"
  initial_user: fedora
  initial_port: 22
```

| Field                           | Meaning                                                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `workflow`                      | `k0s` or `none`. Branches later setup steps; `k0s` nodes are the ones `k0sctl.yaml` is rendered from                            |
| `k0s_role`                      | `controller+worker`, `controller` or `worker`. Only with `workflow: k0s`                                                        |
| `mesh`                          | Optional, default false. Joins the Tailscale mesh                                                                               |
| `public_ingress`                | Optional, default false. Opens 80/443 in firewalld and marks this host as the one whose IPs go into the `edge-ips` ConfigMap    |
| `ip`                            | The node's public address. Also becomes its Kubernetes `ExternalIP`, via the k0s cloud provider's `node-ip-external` annotation |
| `initial_user` / `initial_port` | First-contact login, the provider default, before the admin account exists                                                      |

`ip` is a `pass://` lookup, never a literal — a real address is an identifying value and this
repository is public. See [Secrets](../conventions/secrets.md).

Exactly one host should be a controller. A second controller makes etcd a two-member cluster
with quorum two, which is worse for availability than a single controller, not better.

`mesh` is orthogonal to `workflow`: opt in for any node, cloud or local, that needs mesh
reachability. There is no mesh IP to store — once joined, the node is addressed as
`<hostname>.<tailnet_domain>`, and Tailscale's own resolver keeps that correct across re-keys.
The node's Kubernetes `InternalIP` comes from `k0s_cluster`'s `privateInterface`, which is
interface-based (`tailscale0`), not from that name.

`public_ingress` and `mesh` are both read generically — nothing in `roles/tailscale`,
`roles/firewall_ingress` or `roles/flux_bootstrap` branches on a hostname, so moving public
ingress to a different node is a one-line inventory change.

## Adding a node

```bash
mkdir -p ansible/nodes/<hostname>
$EDITOR ansible/nodes/<hostname>/host.yml
ln -s ../../nodes/<hostname>/host.yml ansible/inventory/host_vars/<hostname>.yml
# then add `<hostname>: {}` under all.hosts in ansible/inventory/hosts.yml
task ans:setup -- <hostname>
task ans:k0s
```

If the node will run its own tenant apps under `nodes/<hostname>.k0s/`, it also needs its own
OpenBao namespace:

```bash
task bao:policy-sync
```

That loops every `nodes/*.k0s/` directory and bootstraps any `node-<hostname>` namespace that
does not exist yet. Then add `infra/external-secrets/config/nodes/<hostname>.yaml` — copy
`kenaz.yaml`, swap the hostname — and list it in the sibling `kustomization.yaml`.
