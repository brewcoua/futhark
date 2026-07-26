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

1. **Routing.** kube-router installs `from <node's pod /24> lookup 77` and puts the peer's mesh
   IP into table 77 pointing at its tunnel. That outranks Tailscale's own pref 5270
   (`lookup 52`), so the packet is routed into the very tunnel whose transport endpoint _is_
   that address. Fixed with one `ip rule` per peer at priority 10, matching only that peer's
   `/32` — never the pod CIDR, so pod-to-pod overlay routing is untouched.

   The priority is load-bearing. kube-router currently installs its rule at pref 99; an earlier
   release used 5209. Anything numerically above kube-router's is silently shadowed and the
   whole script becomes a no-op with no error anywhere — check `ip rule` on the node rather
   than assuming, and re-check after a kube-router bump.

2. **Source address.** tailscaled drops packets whose source is not the node's own tailnet IP,
   as anti-spoofing, so pod-sourced packets still die on egress even once the route is correct
   — with `no route to host`, which reads like a routing fault and is not one. They must be
   masqueraded to the node's mesh IP. Nothing else does this: kube-proxy's `KUBE-POSTROUTING`
   only masquerades service traffic carrying the `0x4000` mark, and tailscaled only installs
   its own `ts-postrouting` chain when acting as a subnet router or exit node.

IPIP solves the _source address_ half for cross-node **pod-to-pod** traffic: the outer header is
sourced from the node's own mesh IP, so it never presents a foreign source to tailscaled. That
is only half of what pod-to-pod needs — see the ACL prerequisite below. The isolating test for
the pod → mesh case, run on a node:

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

### Tailnet ACL prerequisite: `ip-in-ip`

The overlay above only carries traffic if the tailnet ACL permits it. A Tailscale rule that
does not name a protocol matches TCP, UDP, ICMP and SCTP **only** — IPIP is IP protocol 4 and
is silently dropped. Cross-node pod-to-pod then blackholes: the route is correct, the tunnel is
`UP`, nothing is logged, and every packet vanishes.

In the legacy `acls` syntax, `proto` is a single string, so this is its own rule rather than an
extra entry on an existing one. Protocol 4 is named `ip-in-ip` (`ipv4` is an accepted alias),
and only TCP/UDP/SCTP may name ports, so the destination port must be `*`:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:futhark-node"],
      "proto": "ip-in-ip",
      "dst": ["tag:futhark-node:*"]
    }
  ]
}
```

If the policy file uses the newer `grants` syntax, there is no `action` field — pasting the
rule above yields `json: unknown field "action"`. The equivalent grant expresses the protocol
in `ip`:

```json
{
  "grants": [
    {
      "src": ["tag:futhark-node"],
      "dst": ["tag:futhark-node"],
      "ip": ["ip-in-ip:*"]
    }
  ]
}
```

`acls` and `grants` may coexist in one policy file, so adding an `acls` block to a
grants-based file is a valid way to do this.

This is the one piece of the mesh that is **not** reproducible from this repo — the tailnet
policy file lives in the Tailscale admin console, and `tofu/` manages only Bunny DNS. Re-check
it before believing a cross-node networking bug is a node-local fault.

The failure is worth recognising by shape, because it does not look like an ACL problem. Half
of all ClusterIP DNS answers time out while direct-to-pod-IP works, because CoreDNS runs one
pod per node and kube-proxy load-balances 50/50 — only the remote endpoint is unreachable.
Anything that resolves DNS at startup then fails intermittently or crashloops. The test:

```bash
# from a pod, against a pod on the *other* node
ping -c2 <remote pod IP>   # fails => overlay is dropping, check ip-in-ip in the ACL
```
