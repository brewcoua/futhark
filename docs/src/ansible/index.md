# Inventory and roles

Ansible owns everything below Kubernetes: the user you log in as, the SSH configuration, the
firewall, the mesh join, and the k0s install itself. Once Flux is running, Ansible's job is
done — the only reasons to come back are adding a node, re-converging the cluster, and
OpenBao day-2 work.

Run everything through `task ans:*` rather than `ansible-playbook` directly; the tasks set the
working directory `ansible.cfg` expects. See [Task reference](../operations/tasks.md).

## Inventory

`ansible/inventory/hosts.yml` is a bare list of node names. Everything about a node lives in
`ansible/nodes/<hostname>/host.yml`, surfaced to Ansible by a symlink in
`ansible/inventory/host_vars/`. See [Nodes](nodes.md) for the schema and how to add one.

`ansible/inventory/group_vars/all.yml` holds what is shared:

| Variable                                       | Notes                                                                      |
| ---------------------------------------------- | -------------------------------------------------------------------------- |
| `admin.user`, `admin.ssh_pubkey`               | The non-root sudo account created on every host, resolved from Proton Pass |
| `tailnet_domain`                               | The tailnet's MagicDNS suffix. Identifying, so it is a `pass://` lookup    |
| `ssh_port`                                     | The hardened SSH port `ssh_harden` moves sshd to                           |
| `k0s_pod_cidr`, `k0s_service_cidr`             | k0s's own defaults, pinned here as a single source of truth                |
| `ansible_host`, `ansible_user`, `ansible_port` | How Ansible reaches each host                                              |
| `repo_root`, `generated_dir`                   | Repo-relative paths for artifacts that are never committed                 |

Three of those deserve explanation.

**The CIDRs are pinned rather than left implicit** because two things need to agree on them:
`k0s_cluster` writes them into the k0s `ClusterConfig`, and the `tailscale` role needs the pod
CIDR to scope its pod → mesh SNAT rule. `k0s_pod_cidr` is the cluster-wide `/16`; kube-router
carves a `/24` out of it per node, and the SNAT rule must match the `/16` or a peer's pods are
not covered. They are private RFC1918 ranges, not identifying, so they are plain literals.

**`ansible_host` resolves through MagicDNS for mesh nodes** — `<hostname>.<tailnet_domain>` —
and falls back to `node.ip` otherwise. There is no stored mesh IP anywhere in this repo:
Tailscale's own resolver keeps the name correct across re-keys and reassignments, so there is
nothing to update when an address changes. The expression is guarded on `node is defined`
because `k0s_cluster`, `flux_bootstrap` and the OpenBao plays run against `hosts: localhost`,
which is implicit, not in inventory, and has no `node` var.

`setup.yml` still overrides these three with `set_fact` mid-play, for first-time provisioning
where the host does not yet answer as the admin user. Facts beat inventory vars, so that
dance is unaffected by the defaults above.

**`repo_root` is derived from `playbook_dir`, not `inventory_dir`**, for the same
`hosts: localhost` reason — localhost has no `inventory_dir`, and `playbook_dir` is
play-scoped rather than host-scoped.

## Playbooks

| Playbook    | Task                                       | Does                                                                                               |
| ----------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `setup.yml` | `task ans:setup [-- <host>]`               | First contact on a fresh node: update, admin user, SSH hardening, mesh join, firewall. Re-runnable |
| `k0s.yml`   | `task ans:k0s`                             | `k0sctl apply` across the whole fleet, OpenBao's pre-Flux prep, then the Flux bootstrap            |
| `bao.yml`   | `task bao:status` / `task bao:policy-sync` | Day-2 OpenBao, selected by `-e bao_task=`                                                          |

`setup.yml` runs per host and is gated by the node's own flags — the `tailscale` role only
runs when `node.mesh` is true, `firewall_ingress` only when `node.public_ingress` is. Nothing
in any role branches on a hostname, so a future node opts into either by setting the flag.

`k0s.yml` is fleet-wide, not per-host: one `k0sctl apply` converges every `workflow: k0s`
node in inventory at once. It runs against `hosts: localhost` and reaches the cluster over the
network with the k0sctl-fetched kubeconfig — no SSH, no `become`.

`bao.yml` reaches OpenBao by `kubectl exec` into the `openbao-0` pod, not over SSH.

## Roles

| Role                     | Does                                                                                                                   |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `ssh_identity`           | Probes which login answers — the initial provider account or the hardened admin one — so `setup.yml` stays re-runnable |
| `fedora_common`          | Hostname, full system upgrade, base tooling                                                                            |
| `admin_user`             | The key-only, passwordless-sudo admin account                                                                          |
| `ssh_harden`             | Disables root and password login, moves sshd to `ssh_port`, via a `sshd_config.d/` drop-in                             |
| `tailscale`              | Mesh join with a freshly minted single-use auth key, firewalld zoning, and the pod → mesh routing fix                  |
| `firewall_ingress`       | Opens 80/443 in firewalld's public zone. Only on the `public_ingress` node                                             |
| `k0s_cluster`            | Renders `k0sctl.yaml` from inventory, converges the cluster, fetches the kubeconfig                                    |
| `local_path_provisioner` | Installs the `local-path` StorageClass OpenBao's PVC needs on its first reconcile                                      |
| `flux_bootstrap`         | Flux Operator, the git deploy key, the `edge-ips` ConfigMap, then `flux/cluster.yaml`                                  |
| `openbao`                | `prep.yml` (namespace + seal Secret, pre-Flux) and `main.yml` (init + namespace/mount/auth/policy bootstrap, day-2)    |

Two roles are worth knowing in more detail.

### `ssh_identity`

A fresh host answers as `node.initial_user` on `node.initial_port`; once `admin_user` and
`ssh_harden` have run, that login is gone. `ssh_identity` probes the hardened port and picks
accordingly. Probing only the hardened port is sufficient because `admin_user` installs the
key before `ssh_harden` closes the initial one — there is no window where neither works.

### `k0s_cluster`

kubelet's `--node-ip` is pinned to each node's Tailscale mesh IP, deliberately: the Kubernetes
API, etcd and kubelet then bind only to mesh addresses and are never publicly exposed. Several
consequences follow.

k0s would otherwise self-detect `spec.api.address` from the default-route interface, which on
these hosts is the public IP — join tokens would carry an address workers cannot reach. So the
role resolves the controller's mesh address through MagicDNS with `getent` (not a `dig`
lookup, which would pull in dnspython), and asserts the result is inside Tailscale's CGNAT
range `100.64.0.0/10`. That assertion is not paranoia: a stale MagicDNS entry from a deleted
or re-keyed node resolves to something else, and would otherwise be baked silently into
`spec.api.address` and every kubelet's `--node-ip`.

The public IP still has to reach Kubernetes somehow, since kubelet can only ever register
`--node-ip` as `InternalIP`. It arrives as the `k0sproject.io/node-ip-external` annotation,
which the k0s cloud provider reads. `node.ip` is a `pass://` lookup, so the public IP is never
committed.

This decision is also what makes cross-node pod networking non-trivial. See
[Pod to mesh networking](networking.md).

## The `protonpass` lookup

`ansible/plugins/lookup/protonpass.py` resolves `pass://<vault>/<item>/<field>` references by
shelling out to `pass-cli`. It rejects anything not starting with `pass://`, so a literal
cannot slip through by accident. `ansible/ansible.cfg` registers it with
`lookup_plugins = plugins/lookup`.

The rule about what belongs behind a pointer is in [Secrets](../conventions/secrets.md).
