# Pod to mesh networking

Read this before touching `ansible/roles/tailscale`. It was diagnosed the hard way twice.

kubelet's `--node-ip` is pinned to each node's Tailscale mesh IP, on purpose: the Kubernetes
API, etcd and kubelet are then only ever bound to mesh addresses and are never publicly
exposed. Everything below follows from that one decision.

Because the nodes share no L2 segment, k0s's default CNI (kube-router) builds its own IPIP
overlay between their mesh IPs to carry cross-node pod-to-pod traffic. That has two
consequences, both of which break a pod dialing a peer node's **own** mesh address.

This is not a hypothetical case. `konnectivity-agent` does exactly that — it dials the
controller's `konnectivity-server` over the mesh — so while it is broken, `kubectl exec`,
`logs` and `port-forward` are down cluster-wide.

Two paths leave a pod for another node, and they fail for different reasons — which is why the
two fixes below are not interchangeable:

```d2
direction: down

a: node A {
  pod: pod\nsrc = pod IP
  tun: kube-router\nIPIP tunnel
  ts: tailscaled\nmesh IP
  pod -> tun: to a peer *pod* IP
  pod -> ts: to a peer *node's own* mesh IP
  tun -> ts: outer header\nsrc = node mesh IP
}

b: node B {
  bpod: pod
  bts: "tailscaled\nkonnectivity-server, traefik…"
}

a.ts -> b.bts: tailnet
b.bts -> b.bpod

fix1: "1. ip rule per peer /32 at mesh_route_priority\nkube-router's rule would send this into the tunnel\nwhose endpoint IS that address" {
  style: { stroke-dash: 4; fill: transparent }
}
fix2: "2. SNAT to the node's mesh IP\ntailscaled drops foreign source addresses —\nfails as 'no route to host'" {
  style: { stroke-dash: 4; fill: transparent }
}
acl: "tailnet ACL must allow ip-in-ip (proto 4)\nor the tunnel blackholes silently" {
  style: { stroke-dash: 4; fill: transparent }
}

fix1 -> a.ts: { style.stroke-dash: 4 }
fix2 -> a.ts: { style.stroke-dash: 4 }
acl -> a.tun: { style.stroke-dash: 4 }
```

## 1. Routing

kube-router installs `from <node's pod /24> lookup 77` and puts the peer's mesh IP into table
77 pointing at its tunnel. That outranks Tailscale's own pref 5270 (`lookup 52`, the table
`mesh_route_table` names), so the
packet is routed into the very tunnel whose transport endpoint **is** that address.

The fix is one `ip rule` per peer at `mesh_route_priority`, matching only that peer's `/32` — never the
pod CIDR, so pod-to-pod overlay routing is untouched.

The priority is load-bearing. kube-router's own rule priority has moved before: 5209, then 99,
then priority 9 as of kube-router v2.10.0 (k0s v1.36.3) — which silently shadowed this fix at
its old priority 10 and broke every mesh-peer-initiated connection into a pod (backends behind
traefik-edge, since it's hostNetwork and reaches them as the node's own mesh IP), surfacing as
502 Bad Gateway with no error anywhere else in the stack. Check `ip rule` on the node rather
than assuming, and re-check after a kube-router bump.

## 2. Source address

tailscaled drops packets whose source is not the node's own tailnet IP, as anti-spoofing, so
pod-sourced packets still die on egress even once the route is correct. They fail with
`no route to host`, which reads like a routing fault and is not one.

They have to be masqueraded to the node's mesh IP. Nothing else does this: kube-proxy's
`KUBE-POSTROUTING` only masquerades service traffic carrying the `0x4000` mark, and tailscaled
only installs its own `ts-postrouting` chain when acting as a subnet router or exit node.

The SNAT is scoped to peer `/32`s rather than the whole `mesh_cidr` tailnet on purpose:
pods get to reach cluster nodes (konnectivity-agent → konnectivity-server, Prometheus →
traefik on the mesh IP) without inheriting the node's `mesh_node_tag` reach across the
entire tailnet.

Both rules live in `ansible/roles/tailscale/templates/futhark-mesh-routes.sh.j2`, re-applied
by a systemd oneshot because neither `ip rule` nor iptables state survives a reboot.

## The isolating test

Run on a node:

```bash
ping -c2 -I <this node's mesh IP> <peer mesh IP>        # succeeds
ping -c2 -I <this node's pod-bridge IP> <peer mesh IP>  # fails without the SNAT rule
```

Both are locally generated (OUTPUT path, and `tailscale0` is in firewalld's `trusted` zone),
so neither traverses FORWARD. That rules out every firewall hypothesis at once and isolates
the drop to tailscaled itself.

## Tailnet ACL prerequisite: `ip-in-ip`

IPIP solves the source-address half for cross-node **pod-to-pod** traffic on its own — the
outer header is sourced from the node's own mesh IP, so it never presents a foreign source to
tailscaled. But the overlay only carries traffic at all if the tailnet ACL permits it.

A Tailscale rule that does not name a protocol matches TCP, UDP, ICMP and SCTP **only**. IPIP
is IP protocol 4 and is silently dropped. Cross-node pod-to-pod then blackholes: the route is
correct, the tunnel is `UP`, nothing is logged, and every packet vanishes.

In the legacy `acls` syntax `proto` is a single string, so this is its own rule rather than an
extra entry on an existing one. Protocol 4 is named `ip-in-ip` (`ipv4` is an accepted alias),
and only TCP, UDP and SCTP may name ports, so the destination port must be `*`:

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

If the policy file uses the newer `grants` syntax there is no `action` field, and pasting the
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

The policy file is managed in [`tofu/tailscale`](../tofu/tailscale.md), which also carries a
`tests` entry asserting this rule. Tests are evaluated when the policy is written, so a
regression aborts `tofu apply` and the tailnet keeps its previous policy rather than losing
the overlay. Re-check the live policy before believing a cross-node networking bug is a
node-local fault — if the tailnet was edited in the admin console rather than through tofu,
the two can still have drifted.

The failure is worth recognising by shape, because it does not look like an ACL problem. Half
of all ClusterIP DNS answers time out while direct-to-pod-IP works, because CoreDNS runs one
pod per node and kube-proxy load-balances 50/50 — only the remote endpoint is unreachable.
Anything that resolves DNS at startup then fails intermittently or crashloops. The test:

```bash
# from a pod, against a pod on the *other* node
ping -c2 <remote pod IP>   # fails => overlay is dropping, check ip-in-ip in the ACL
```
