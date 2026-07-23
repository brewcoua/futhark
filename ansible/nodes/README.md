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

If `workflow: k0s`, the node also needs its own Infisical machine identity (read-only on
`/nodes/<hostname>/**` — see `infra/infisical-operator/README.md`): create the identity + role
in Infisical, then add the Proton Pass items `futharkd/<hostname>/infisical-client-id` and
`futharkd/<hostname>/infisical-client-secret` before running `task ans:k0s`.
