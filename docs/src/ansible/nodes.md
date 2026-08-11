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
  hostname: <hostname>
  os: fedora
  workflow: k8s
  k8s_role: controller
  mesh: true
  public_ingress: true
  ip: "{{ nodes[inventory_hostname].ip }}"
  initial_user: fedora
  initial_port: 22
```

| Field                           | Meaning                                                                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `workflow`                      | `k8s` or `none`. Branches later setup steps; `k8s` nodes are the ones `playbooks/k8s.yml` installs k3s on                                            |
| `k8s_role`                      | `controller` or `worker`. Only with `workflow: k8s`. A k3s server is a worker too unless tainted                                                     |
| `mesh`                          | Optional, default false. Joins the NetBird mesh                                                                                                      |
| `public_ingress`                | Optional, default false. Opens 443 in firewalld and marks this host as the one `PUBLIC_IP` and `MESH_IP` in `config/sops/cluster.sops.yaml` describe |
| `app_tier`                      | Optional, default false. This host carries apps under `nodes/<hostname>.k8s/`, so it gets an `infisical-node-<hostname>` tier                        |
| `ip`                            | The node's public address. Also becomes its Kubernetes `ExternalIP`, via k3s's `node-external-ip`                                                    |
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
deliberate: every `hostvars[x].node.ip` in the roles and the k3s config template keeps working
unchanged, and Jinja resolves the indirection at use time. See
[Secrets](../conventions/secrets.md).

Exactly one host should be a controller. A second controller makes etcd a two-member cluster
with quorum two, which is worse for availability than a single controller, not better.

`mesh` is orthogonal to `workflow`: opt in for any node, cloud or local, that needs mesh
reachability. There is no mesh IP to store. Once joined, the node is addressed as
`<hostname>.<mesh_dns_domain>`, and NetBird's own resolver keeps that correct across re-keys.
The node's Kubernetes `InternalIP` comes from `k8s_cluster`'s `node-ip`, which is the address
recorded in `node.mesh_ip`, not from that name.

`public_ingress` and `mesh` are both read generically. Nothing in `roles/netbird`,
`roles/firewall_ingress` or `roles/flux_bootstrap` branches on a hostname, so on this plane moving
public ingress is a one-line inventory change.

The other planes are not so lucky. `public_ingress` gates the `firewall_ingress` role and nothing
else. No tofu module and nothing in the Flux tree reads it, so the edge node is named independently
in five more places, with nothing detecting disagreement between them. Moving public ingress means
changing all six together:

| Where                                         | What names the edge node                                          |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `ansible/nodes/<host>/host.yml`               | `public_ingress: true`, which opens 443 and lowers the port floor |
| `config/sops/cluster.sops.yaml`               | `PUBLIC_IP` and `MESH_IP` must be that node's addresses           |
| `tofu/bunny/refs.env`                         | `TF_VAR_edge_public_ip` reads `["nodes"][<host>]["ip"]`           |
| `tofu/netbird/refs.env`                       | `TF_VAR_mesh_ip` reads `["nodes"][<host>]["mesh_ip"]`             |
| `infra/traefik-edge/app/helmrelease.yaml`     | `nodeSelector`, required: the `hostIP`s exist only on that node   |
| `infra/traefik-internal/app/helmrelease.yaml` | `nodeSelector`, required for the same reason                      |

Miss a `nodeSelector` and that Traefik pod sits `Pending`. Miss `PUBLIC_IP` and the edge never
binds. Miss `tofu/bunny/refs.env` and the public `A` record points at the wrong host; miss
`tofu/netbird/refs.env` and every internal hostname does.

## Adding a node

```bash
mkdir -p ansible/nodes/<hostname> ansible/inventory/host_vars/<hostname>
$EDITOR ansible/nodes/<hostname>/host.yml

# add a `<hostname>:` entry under `nodes`, with its `ip` and an empty `mesh_ip`
just ops sops config/sops/ops.sops.yaml

ln -s ../../../nodes/<hostname>/host.yml ansible/inventory/host_vars/<hostname>/host.yml
# then add `<hostname>: {}` under all.hosts in ansible/inventory/hosts.yml
just ans setup <hostname>
just ans k8s
```

`just ans setup` writes the node's mesh address back into `nodes.<hostname>.mesh_ip`. Commit that
change before running `just ans k8s`, which reads it.

Verify: `just ans ping` reaches the new host, `ssh <hostname> netbird status` reports connected,
and `just ks nodes` lists it `Ready`.

If the node will run its own tenant apps under `nodes/<hostname>.k8s/`, it also needs its own
Infisical operator tier, which is three files and one defaults entry, listed in
[Cluster infrastructure](../gitops/infra.md#adding-a-node-tier).
