# Nodes

One `<hostname>/host.yml` per node — the source of truth for that host. Symlink it into
`ansible/inventory/host_vars/<hostname>.yml` so Ansible picks it up automatically.

```yaml
node:
  hostname: kenaz
  os: fedora # fedora only for now; more OSes later
  workflow: k0s # k0s | podman | none — branches later setup steps
  k0s_role:
    controller+worker # controller+worker | controller | worker — only when workflow: k0s;
    # drives ansible/roles/k0s_cluster's generated k0sctl.yaml
  mesh:
    true # optional, default false — joins the Tailscale mesh (see ansible/roles/tailscale).
    # Orthogonal to workflow: opt in for any node (cloud or local) that needs mesh reachability,
    # e.g. a VPS node reaching a home node, or OpenBao staying off the public internet.
  mesh_ip:
    100.64.0.10 # required if mesh: true — the tailnet IP, used instead of `ip` for
    # SSH/API traffic (k0sctl, etc.) once the node has joined (see ansible/roles/k0s_cluster).
  apps: [] # optional, default [] — app-specific roles to run, only meaningful for workflow:
    # podman (a podman node is one process per app; see ansible/playbooks/podman.yml). A k0s
    # node's apps live under nodes/<hostname>.k0s/ instead, not here.
  ip: 203.0.113.10
  initial_user: fedora # first-contact login (provider default, before `admin_user` exists)
  initial_port: 22
```

To add a node:

```bash
mkdir -p ansible/nodes/<hostname>
$EDITOR ansible/nodes/<hostname>/host.yml
ln -s ../../nodes/<hostname>/host.yml ansible/inventory/host_vars/<hostname>.yml
# add <hostname>: {} under all.hosts in ansible/inventory/hosts.yml
```

If `workflow: k0s`, the node also needs its own OpenBao namespace (`node-<hostname>`, read-only
via that namespace's `kubernetes` auth role — see `infra/external-secrets/README.md` and
`ansible/roles/openbao/`): re-run `task ans:podman` against ogma to bootstrap the namespace, then
add `infra/external-secrets/app/nodes/<hostname>.yaml` (copy `kenaz.yaml`, swap the hostname).
