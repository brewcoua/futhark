# Nodes

One `<hostname>/host.yml` per node — the source of truth for that host. Symlink it into
`ansible/inventory/host_vars/<hostname>.yml` so Ansible picks it up automatically.

```yaml
node:
  hostname: kenaz
  os: fedora
  workflow: k0s # k0s | none — branches later setup steps
  k0s_role:
    controller+worker # controller+worker | controller | worker — only when workflow: k0s;
    # drives ansible/roles/k0s_cluster's generated k0sctl.yaml. Exactly one host should be a
    # controller (or controller+worker) — a second controller makes etcd a 2-member cluster
    # with quorum 2, worse for availability than a single controller, not better.
  mesh:
    true # optional, default false — joins the Tailscale mesh (see ansible/roles/tailscale).
    # Orthogonal to workflow: opt in for any node (cloud or local) that needs mesh reachability,
    # e.g. a VPS node reaching a home node. No mesh_ip to store: once joined, the node is
    # addressed as <hostname>.<tailnet_domain> (ansible/inventory/group_vars/all.yml) for
    # SSH/API traffic (k0sctl, etc.) — Tailscale's own MagicDNS resolver keeps that name
    # correct across re-keys/reassignments, nothing here to update. The node's Kubernetes
    # InternalIP instead comes from ansible/roles/k0s_cluster's privateInterface, which is
    # interface-based (tailscale0), not this hostname.
  ip:
    203.0.113.10 # also becomes the node's Kubernetes ExternalIP, via the k0s cloud
    # provider's node-ip-external annotation — see ansible/roles/k0s_cluster.
  initial_user: fedora # first-contact login (provider default, before `admin_user` exists)
  initial_port: 22
```

A k0s node's own tenant apps live under `nodes/<hostname>.k0s/`, one directory per app — not
every k0s node needs one (see `nodes/README.md`). Cluster-wide infra pinned to a specific node
(OpenBao and Pocket ID, both pinned to `ogma`) is a `nodeSelector` in `infra/openbao/` /
`infra/auth/` instead, not a per-node directory here.

To add a node:

```bash
mkdir -p ansible/nodes/<hostname>
$EDITOR ansible/nodes/<hostname>/host.yml
ln -s ../../nodes/<hostname>/host.yml ansible/inventory/host_vars/<hostname>.yml
# add <hostname>: {} under all.hosts in ansible/inventory/hosts.yml
```

If the node will run its own tenant apps (`nodes/<hostname>.k0s/`), it also needs its own
OpenBao namespace (`node-<hostname>`, read-only via that namespace's `kubernetes` auth role —
see `infra/external-secrets/README.md` and `ansible/roles/openbao/`): run
`task bao:policy-sync` to bootstrap the namespace (it loops every `nodes/*.k0s/` directory,
see `ansible/roles/openbao/tasks/main.yml`), then add
`infra/external-secrets/config/nodes/<hostname>.yaml` (copy `kenaz.yaml`, swap the hostname).
