# Inventory and roles

Where node facts live, which playbook and role does what, and how a secret reaches a task. Read
this before editing inventory or adding a role.

Ansible owns everything below Kubernetes: the user you log in as, the SSH configuration, the
firewall, the mesh join, and the k0s install itself. Once Flux is running, Ansible's job is done.
The only reasons to come back are adding a node and re-converging the cluster.

Run everything through `just ans` rather than `ansible-playbook` directly, because the recipes set
the working directory `ansible.cfg` expects. See [Recipe reference](../operations/recipes.md).

## Inventory

`ansible/inventory/hosts.yml` is a bare list of node names. Everything about a node lives in
`ansible/nodes/<hostname>/host.yml`, surfaced to Ansible by a symlink in
`ansible/inventory/host_vars/<hostname>/`. Its one identifying value, the address, comes from
`config/sops/ops.sops.yaml`. See [Nodes](nodes.md) for the schema and how to add one.

`ansible/inventory/group_vars/all/` holds what is shared, all of it in the clear:

| Variable                                       | Notes                                                                                   |
| ---------------------------------------------- | --------------------------------------------------------------------------------------- |
| `admin.user`, `admin.ssh_pubkey`               | The non-root sudo account created on every host. Rendered, not committed                |
| `nodes`, `dns`                                 | Node addresses and the domain, loaded out of `.generated/` by `nodes.yml` and `dns.yml` |
| `ssh_port`                                     | The hardened SSH port `ssh_harden` moves sshd to                                        |
| `ansible_host`, `ansible_user`, `ansible_port` | How Ansible reaches each host                                                           |
| `repo_root`, `generated_dir`                   | Repo-relative paths for artifacts that are never committed                              |

`network.yml` beside it holds every constant more than one role has an opinion about:

| Variable                                  | Notes                                                                                                                                               |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mesh_cidr`, `mesh_cidr_regex`            | The mesh's address pool, as a CIDR and, for `assert` which has no membership test, as a regex. `tofu/netbird` sets it on the account from this file |
| `mesh_interface`, `mesh_dns_domain`       | NetBird's WireGuard interface (`netbird0`) and the domain it answers peer names under, composed from `dns.yml`                                      |
| `mesh_node_group`                         | The group every peer joins, alongside its `node.workflow` group. Both are declared in `tofu/netbird`                                                |
| `mesh_route_table`, `mesh_route_priority` | The routing-rule slot the pod-to-mesh script in `roles/netbird` claims                                                                              |
| `k0s_pod_cidr`, `k0s_service_cidr`        | k0s's own defaults, pinned as a single source of truth                                                                                              |

**These are collected rather than written at each use site** because they had drifted into
different spellings of the same fact: the mesh range was a literal in fail2ban's `ignoreip`,
a literal again in the mesh role's firewalld loop, and a hand-expanded regex in `k0s_cluster`'s
assert. A constant with three spellings is three constants. The CIDRs specifically need three
consumers to agree: `k0s_cluster` writes them into the k0s `ClusterConfig`, `tofu/netbird`
reads `k0s_service_cidr` out of this file for the route it advertises into the mesh, and `netbird`
needs the pod CIDR to scope its pod-to-mesh SNAT rule. `k0s_pod_cidr` is the cluster-wide `/16`,
kube-router carves a `/24` out of it per node, and the SNAT rule must match the `/16` or a peer's
pods are not covered. All of these are private or RFC6598 ranges, not identifying, so
they are plain literals.

**`ansible_host` resolves through NetBird's DNS for mesh nodes**, as
`<hostname>.<mesh_dns_domain>`, and falls back to `node.ip` otherwise. There is no stored mesh IP
anywhere in this repository. NetBird's own resolver keeps the name correct across re-keys and
reassignments, so there is nothing to update when an address changes. The expression is guarded on `node is defined`
because `k0s_cluster` and `flux_bootstrap` run against `hosts: localhost`,
which is implicit, not in inventory, and has no `node` var.

`setup.yml` still overrides these three with `set_fact` mid-play, for first-time provisioning
where the host does not yet answer as the admin user. Facts beat inventory vars, so that
dance is unaffected by the defaults above.

**`repo_root` is derived from `playbook_dir`, not `inventory_dir`**, for the same
`hosts: localhost` reason. localhost has no `inventory_dir`, and `playbook_dir` is play-scoped
rather than host-scoped.

## Playbooks

| Playbook    | Recipe                    | Does                                                                                               |
| ----------- | ------------------------- | -------------------------------------------------------------------------------------------------- |
| `setup.yml` | `just ans setup [<host>]` | First contact on a fresh node: update, admin user, SSH hardening, mesh join, firewall. Re-runnable |
| `k0s.yml`   | `just ans k0s`            | `k0sctl apply` across the whole fleet, the `local-path` StorageClass, then the Flux bootstrap      |

`setup.yml` runs per host and is gated by the node's own flags. The `netbird` role only runs when
`node.mesh` is true, and `firewall_ingress` only when `node.public_ingress` is. Nothing
in any role branches on a hostname, so a future node opts into either by setting the flag.

It also carries tags, so a single concern can be re-converged without running the whole thing:

| Tag        | Roles                          |
| ---------- | ------------------------------ |
| `base`     | `fedora_common`                |
| `access`   | `admin_user`, `ssh_harden`     |
| `firewall` | `fail2ban`, `firewall_ingress` |
| `mesh`     | `netbird`                      |

`admin_user` and `ssh_harden` share one tag on purpose: `ssh_harden` disables root and password
login, so running it without `admin_user` locks the host out permanently. `ssh_identity` and the
post-play `set_fact` are tagged `always`, because they decide which login and port every other
task connects with. Skipping them would have `--tags mesh` dial a fresh host as an admin user that
does not exist yet.

`k0s.yml` is tagged the same way: `k0s`, `storage`, `flux`.

`k0s.yml` is fleet-wide, not per-host: one `k0sctl apply` converges every `workflow: k0s`
node in inventory at once. It runs against `hosts: localhost` and reaches the cluster over the
network with the k0sctl-fetched kubeconfig, with no SSH and no `become`.

## Roles

| Role                     | Does                                                                                                                 |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `ssh_identity`           | Probes which login answers, the initial provider account or the hardened admin one, so `setup.yml` stays re-runnable |
| `fedora_common`          | Hostname, full system upgrade, base tooling                                                                          |
| `admin_user`             | The key-only, passwordless-sudo admin account                                                                        |
| `ssh_harden`             | Disables root and password login, moves sshd to `ssh_port`, via a `sshd_config.d/` drop-in                           |
| `firewalld`              | Nothing but "the daemon is up and answering". A dependency of the four roles that write firewalld rules              |
| `fail2ban`               | Bans brute force on `ssh_port`, and repeat offenders, through firewalld                                              |
| `netbird`                | Mesh join with a freshly minted single-use setup key, firewalld zoning, and the pod-to-mesh routing fix              |
| `firewall_ingress`       | Opens 443 in firewalld's public zone. Only on the `public_ingress` node                                              |
| `k0s_cluster`            | Renders `k0sctl.yaml` from inventory, converges the cluster, writes the kubeconfig                                   |
| `local_path_provisioner` | Installs the `local-path` StorageClass that monitoring, `auth` and `actual` bind PVCs against                        |
| `flux_bootstrap`         | Flux Operator, the seed Secrets, then `flux/cluster.yaml`                                                            |

Ordering between them is declared in each role's `meta/main.yml`, not left to the order of the
playbook's role list. `ssh_harden` depends on `admin_user` for the lockout reason above, and the
four firewall-writing roles depend on `firewalld`. That last one used to be two tasks inside
`ssh_harden`, which made "the mesh role needs a running firewalld" an ordering fact you could only
learn by reading `setup.yml` top to bottom. Ansible runs a role once per play regardless of how
many times it is reached, so the dependencies cost nothing at runtime, though `--list-tasks`
prints the pre-deduplication list and will show them repeated.

Four roles are worth knowing in more detail.

### `fedora_common`

`dnf upgrade` on `"*"`, then a reboot if `needs-restarting -r` asks for one. Both are gated:
`fedora_common_upgrade` and `fedora_common_reboot`, defaulting true. Without them, asking for an
unrelated change on a node carrying live workloads, such as re-converging the mesh, would upgrade
and reboot it as a side effect. `-e fedora_common_upgrade=false` converges hostname and base
tooling only. `-e fedora_common_reboot=false` upgrades now and reboots in a window, and the run
still reports whether one is pending.

### `fail2ban`

Two jails, both in `jail.d/10-futhark.local`: `sshd` on `ssh_port`, and `recidive`, which
re-bans anything the first jail catches repeatedly. Bans are enforced by firewalld, from the
`firewallcmd-rich-rules` action Fedora's own `jail.d/00-firewalld.conf` already sets, which is the
same firewall every other role touches.

`ignoreip` covers loopback, the mesh's CGNAT range and both cluster CIDRs. Ops SSH and
`k0sctl` arrive over the mesh, so without that line a misfiring jail could lock the operator
out of every node at once.

The role also redirects fail2ban's own logging from the journal to `/var/log/fail2ban.log`, in
`fail2ban.d/10-futhark.conf`. `recidive` needs a readable log to count bans in, and the file is
what carries ban events into VictoriaLogs. See
[Cluster infrastructure](../gitops/infra.md#host-logs). That is why `recidive` overrides the
default `systemd` backend with `polling`: it reads the file, not the journal.

### `ssh_identity`

A fresh host answers as `node.initial_user` on `node.initial_port`; once `admin_user` and
`ssh_harden` have run, that login is gone. `ssh_identity` probes the hardened port and picks
accordingly. Probing only the hardened port is sufficient because `admin_user` installs the key
before `ssh_harden` closes the initial one, so there is no window where neither works.

### `k0s_cluster`

kubelet's `--node-ip` is pinned to each node's NetBird mesh IP, deliberately: the Kubernetes
API, etcd and kubelet then bind only to mesh addresses and are never publicly exposed. Several
consequences follow.

k0s would otherwise self-detect `spec.api.address` from the default-route interface, which on
these hosts is the public IP, so join tokens would carry an address workers cannot reach. The role
pins it to the controller's mesh address instead, read from inventory as `node.mesh_ip`.

That value is not resolved at converge time. The management server assigns a mesh address at
registration and it cannot be chosen in advance, so `roles/netbird` reads it back out of
`netbird status --json` after the join and records it into
the `nodes` map in `config/sops/ops.sops.yaml`, which `group_vars/all/nodes.yml` loads back. Writing
it down rather than looking it up each run is what lets `playbooks/k0s.yml` stay
`hosts: localhost` in a separate invocation from `setup.yml`, without requiring the operator's
own workstation to be on the mesh. The write is guarded by a compare, because SOPS
re-encryption changes the ciphertext even when the plaintext has not.

The role then asserts every recorded address is non-empty and inside NetBird's CGNAT range
(`mesh_cidr`). That assertion is not paranoia: a node deleted and re-registered picks up a
different address, and a stale value would otherwise be baked silently into `spec.api.address`
and every kubelet's `--node-ip`.

The public IP still has to reach Kubernetes somehow, since kubelet can only ever register
`--node-ip` as `InternalIP`. It arrives as the `k0sproject.io/node-ip-external` annotation,
which the k0s cloud provider reads. `node.ip` comes from the encrypted `config/sops/ops.sops.yaml`, so
the public IP is never committed in the clear.

This decision is also what makes cross-node pod networking non-trivial. See
[Pod to mesh networking](networking.md).

Two idempotency notes. `k0sctl apply` writes the kubeconfig itself, via `--kubeconfig-out`, so
there is no second `k0sctl kubeconfig` invocation whose `--config` could drift from the first
one's. And k0sctl has no "nothing to do" signal. It walks its whole phase list every run and exits
0 either way, so the task matches the lines k0sctl prints only when it actually mutates a host. Re-check those markers after a k0sctl bump: one that quietly stops matching turns the task
into "never changed". `kubectl annotate` needs no such guess, since `--overwrite` reports
`not annotated` when the value was already right.

## How secrets reach a play

Two mechanisms, no custom code in this repo any more.

Both go through `just ans render-secrets`, which decrypts into `ansible/.generated/`. Nothing is
decrypted at load time, and no task mentions SOPS.

Identifying values land in `nodes.yml`, `cluster.yml` and the `admin` subtree of `secrets.yml`,
which `group_vars/all/nodes.yml`, `group_vars/all/dns.yml` and `group_vars/all/admin.yml` read with
a `file` lookup. They are inventory-level rather than a playbook's `vars_files` because
`playbooks/k0s.yml` runs against `localhost` and still reaches `hostvars[<node>].node.mesh_ip` and
`hostvars[<node>].admin.user`, which resolve only if every host carries the variable itself.
So `admin.user` and `node.ip` are ordinary variables at the point of use.

Crown-jewel values come from Proton Pass. `just ans render-secrets` decrypts the `ansible` subtree
of `config/sops/ops.sops.yaml` and pipes it through `pass-cli inject` into
`ansible/.generated/secrets.yml`. The playbooks load that with `vars_files`, so the roles that need
one, `flux_bootstrap` and `netbird`, both `no_log: true`, reference an ordinary variable like
`secrets.flux.deploy_key`. `ans setup` and `ans k0s` depend on
that render, so it is not a step you run by hand. It needs a Proton Pass session, and
`pass-cli info` checks for one.

Which store a given value belongs in is [Secrets](../conventions/secrets.md).
