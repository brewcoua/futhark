# Nodes

The per-host schema, what each field decides, and how to add a node end to end. At the end of
[Adding a node](#adding-a-node) the host is provisioned, on the mesh, and part of the cluster.

`ansible/nodes/<hostname>/host.yml` is the source of truth for a host, and carries everything
reviewable in a diff. Its one identifying value, the address, lives in the `nodes` map of
`config/sops/ops.sops.yaml`. `ansible/inventory/host_vars/<hostname>/` holds a symlink to `host.yml`,
which is how Ansible picks it up.

Do not confuse `ansible/nodes/` with the repository-root `nodes/`. This one is provisioning data:
identity, address, and how to reach and bootstrap the host. The other is workload definition, what
runs once the host exists. See [Node apps](../gitops/nodes.md).

## Schema

```yaml
node:
  hostname: kenaz
  os: fedora
  workflow: k0s
  k0s_role: controller+worker
  mesh: true
  public_ingress: true
  ip: "{{ nodes[inventory_hostname].ip }}"
  initial_user: fedora
  initial_port: 22
```

| Field                           | Meaning                                                                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `workflow`                      | `k0s` or `none`. Branches later setup steps; `k0s` nodes are the ones `k0sctl.yaml` is rendered from                                                 |
| `k0s_role`                      | `controller+worker`, `controller` or `worker`. Only with `workflow: k0s`                                                                             |
| `mesh`                          | Optional, default false. Joins the NetBird mesh                                                                                                      |
| `public_ingress`                | Optional, default false. Opens 443 in firewalld and marks this host as the one `PUBLIC_IP` and `MESH_IP` in `config/sops/cluster.sops.yaml` describe |
| `app_tier`                      | Optional, default false. This host carries apps under `nodes/<hostname>.k0s/`, so it gets an `infisical-node-<hostname>` tier                        |
| `ip`                            | The node's public address. Also becomes its Kubernetes `ExternalIP`, via the k0s cloud provider's `node-ip-external` annotation                      |
| `initial_user` / `initial_port` | First-contact login, the provider default, before the admin account exists                                                                           |

`ip` stays a reference, never a literal, because a real address is an identifying value and this
repository is public. The `nodes` map comes from `config/sops/ops.sops.yaml`:

```yaml
nodes:
  kenaz:
    ip: 203.0.113.10
    mesh_ip: ""
```

Keeping the reference inside the `node:` dict rather than moving the field out of it is
deliberate: every `hostvars[x].node.ip` in the roles and the k0sctl template keeps working
unchanged, and Jinja resolves the indirection at use time. See
[Secrets](../conventions/secrets.md).

Exactly one host should be a controller. A second controller makes etcd a two-member cluster
with quorum two, which is worse for availability than a single controller, not better.

`mesh` is orthogonal to `workflow`: opt in for any node, cloud or local, that needs mesh
reachability. There is no mesh IP to store. Once joined, the node is addressed as
`<hostname>.<mesh_dns_domain>`, and NetBird's own resolver keeps that correct across re-keys.
The node's Kubernetes `InternalIP` comes from `k0s_cluster`'s `privateInterface`, which is
interface-based (`netbird0`), not from that name.

`public_ingress` and `mesh` are both read generically. Nothing in `roles/netbird`,
`roles/firewall_ingress` or `roles/flux_bootstrap` branches on a hostname, so moving public
ingress to a different node is a one-line inventory change.

## Adding a node

```bash
mkdir -p ansible/nodes/<hostname> ansible/inventory/host_vars/<hostname>
$EDITOR ansible/nodes/<hostname>/host.yml

# add a `<hostname>:` entry under `nodes`, with its `ip` and an empty `mesh_ip`
just ops sops config/sops/ops.sops.yaml

ln -s ../../../nodes/<hostname>/host.yml ansible/inventory/host_vars/<hostname>/host.yml
# then add `<hostname>: {}` under all.hosts in ansible/inventory/hosts.yml
just ans setup <hostname>
just ans k0s
```

`just ans setup` writes the node's mesh address back into `nodes.<hostname>.mesh_ip`. Commit that
change before running `just ans k0s`, which reads it.

Verify: `just ans ping` reaches the new host, `ssh <hostname> netbird status` reports connected,
and `just ks nodes` lists it `Ready`.

If the node will run its own tenant apps under `nodes/<hostname>.k0s/`, it also needs its own
Infisical operator tier, which is three files and one defaults entry, listed in
[Cluster infrastructure](../gitops/infra.md#adding-a-node-tier).
