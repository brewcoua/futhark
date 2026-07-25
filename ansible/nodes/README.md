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

## Pod → mesh networking

Worth reading before touching `ansible/roles/tailscale` — this was diagnosed the hard way
twice.

kubelet's `--node-ip` is pinned to each node's Tailscale mesh IP, on purpose: the Kubernetes
API, etcd and kubelet are then only ever bound to mesh addresses and are never publicly
exposed. Everything below follows from that one decision.

Because the nodes share no L2 segment, k0s's default CNI (kube-router) builds its own IPIP
overlay between their mesh IPs to carry cross-node pod-to-pod traffic. Two consequences, both
of which break a pod dialing a peer node's _own_ mesh address:

1. **Routing.** kube-router installs `from <pod CIDR> lookup 77` at pref 5209 and puts the
   peer's mesh IP into table 77 pointing at its tunnel. That outranks Tailscale's own
   pref 5270 (`lookup 52`), so the packet is routed into the very tunnel whose transport
   endpoint _is_ that address. Fixed with one `ip rule` per peer at priority 100, matching
   only that peer's `/32` — never the pod CIDR, so pod-to-pod overlay routing is untouched.

2. **Source address.** tailscaled drops packets whose source is not the node's own tailnet IP,
   as anti-spoofing, so pod-sourced packets still die on egress even once the route is correct
   — with `no route to host`, which reads like a routing fault and is not one. They must be
   masqueraded to the node's mesh IP. Nothing else does this: kube-proxy's `KUBE-POSTROUTING`
   only masquerades service traffic carrying the `0x4000` mark, and tailscaled only installs
   its own `ts-postrouting` chain when acting as a subnet router or exit node.

This is why cross-node **pod-to-pod already works**: IPIP wraps it in an outer header sourced
from the node's own mesh IP, so it never presents a foreign source to tailscaled. Only
_unencapsulated_ pod → mesh traffic fails. The isolating test, run on a node:

```bash
ping -c2 -I <this node's mesh IP> <peer mesh IP>   # succeeds
ping -c2 -I <this node's pod-bridge IP> <peer mesh IP>   # fails without the SNAT rule
```

Both are locally generated (OUTPUT path, `tailscale0` is in firewalld's `trusted` zone), so
neither traverses FORWARD — which rules out every firewall hypothesis and isolates the drop to
tailscaled itself.

The SNAT is scoped to peer `/32`s rather than the whole `100.64.0.0/10` tailnet on purpose: pods
get to reach cluster nodes (konnectivity-agent → konnectivity-server, Prometheus → traefik on
the mesh IP) without inheriting the node's `tag:futhark-node` reach across the entire tailnet.

Both rules live in `roles/tailscale/templates/futhark-mesh-routes.sh.j2`, re-applied by a
systemd oneshot because neither `ip rule` nor iptables state survives a reboot.
