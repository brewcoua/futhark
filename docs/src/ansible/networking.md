# Pod to mesh networking

Read this before touching `ansible/roles/netbird`.

kubelet's `--node-ip` is pinned to each node's NetBird mesh IP, on purpose: the Kubernetes
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
  ts: netbird\nmesh IP
  pod -> tun: to a peer *pod* IP
  pod -> ts: to a peer *node's own* mesh IP
  tun -> ts: outer header\nsrc = node mesh IP
}

b: node B {
  bpod: pod
  bts: "netbird\nkonnectivity-server, traefik…"
}

a.ts -> b.bts: mesh
b.bts -> b.bpod

fix1: "1. ip rule per peer /32 at mesh_route_priority\nkube-router's rule would send this into the tunnel\nwhose endpoint IS that address" {
  style: { stroke-dash: 4; fill: transparent }
}
fix2: "2. SNAT to the node's mesh IP\nthe WireGuard peer drops foreign source addresses —\nfails as 'no route to host'" {
  style: { stroke-dash: 4; fill: transparent }
}
acl: "the mesh policy must pass every protocol\nor the IPIP tunnel blackholes silently" {
  style: { stroke-dash: 4; fill: transparent }
}

fix1 -> a.ts: { style.stroke-dash: 4 }
fix2 -> a.ts: { style.stroke-dash: 4 }
acl -> a.tun: { style.stroke-dash: 4 }
```

## 1. Routing

kube-router installs `from <node's pod /24> lookup 77` and puts the peer's mesh IP into table
77 pointing at its tunnel, so the packet is routed into the very tunnel whose transport
endpoint **is** that address.

The fix is one `ip rule` per peer at `mesh_route_priority`, matching only that peer's `/32` —
never the pod CIDR, so pod-to-pod overlay routing is untouched. It looks the peer up in
`mesh_route_table`, which the same script populates with a `<peer>/32 dev netbird0` route: the table
is ours and holds exactly what is written into it, rather than depending on where the VPN
client happens to install its own routes. NetBird keeps those in table 7120, with rules at
priorities 105 and 110 — well clear of `mesh_route_priority`.

The priority is load-bearing. kube-router's own rule priority has moved before: 5209, then 99,
then priority 9 as of kube-router v2.10.0 (k0s v1.36.3) — which silently shadowed this fix at
its old priority 10 and broke every mesh-peer-initiated connection into a pod (backends behind
traefik-edge, since it's hostNetwork and reaches them as the node's own mesh IP), surfacing as
502 Bad Gateway with no error anywhere else in the stack. Check `ip rule` on the node rather
than assuming, and re-check after a kube-router bump.

## 2. Source address

The WireGuard peer drops packets whose source is not the node's own mesh address, as
anti-spoofing, so pod-sourced packets still die on egress even once the route is correct. They fail with
`no route to host`, which reads like a routing fault and is not one.

They have to be masqueraded to the node's mesh IP. Nothing else does this: kube-proxy's
`KUBE-POSTROUTING` only masquerades service traffic carrying the `0x4000` mark, and NetBird
only masquerades traffic for the network routes it advertises, which pod-to-peer traffic is
not.

The SNAT is scoped to peer `/32`s rather than the whole `mesh_cidr` on purpose: pods get to
reach cluster nodes (konnectivity-agent → konnectivity-server, Prometheus → traefik on the mesh
IP) without inheriting the node's own reach across the entire mesh.

All three rules live in `ansible/roles/netbird/templates/futhark-mesh-routes.sh.j2`, re-applied
by a systemd oneshot because neither `ip rule`, a route in a custom table, nor iptables state
survives a reboot.

The script reads the peer set out of `netbird status --json` each time it runs, rather than
having Ansible resolve peer addresses and bake them in. A peer re-registering onto a different
mesh address would otherwise strand these rules until someone ran Ansible again — over the very
mesh that is now half broken. It tears down everything it owns and rebuilds from the current peer
set, so a peer that has gone away leaves nothing behind; the SNAT rules sit in their own
`FUTHARK-MESH` chain so they can be flushed as a set. [The mesh watchdog](mesh-watchdog.md)
re-runs the unit on every healthy probe, which is what makes drift correct itself.

## The isolating test

Run on a node:

```bash
ping -c2 -I <this node's mesh IP> <peer mesh IP>        # succeeds
ping -c2 -I <this node's pod-bridge IP> <peer mesh IP>  # fails without the SNAT rule
```

Both are locally generated (OUTPUT path, and `netbird0` is in firewalld's `trusted` zone), so
neither traverses FORWARD. That rules out every firewall hypothesis at once and isolates the
drop to the mesh client itself.

## The all-protocol policy rule

IPIP solves the source-address half for cross-node **pod-to-pod** traffic on its own — the
outer header is sourced from the node's own mesh IP, so it never presents a foreign source to
the mesh client. But the overlay only carries traffic at all if the mesh policy permits it.

NetBird policy rules name a protocol: `tcp`, `udp`, `icmp`, `netbird-ssh`, or `all`. IPIP is IP
protocol 4, so only `all` passes it. Anything narrower and cross-node pod-to-pod blackholes:
the route is correct, the tunnel is `UP`, nothing is logged, and every packet vanishes.

That is what `netbird_policy.k0s` in [`tofu/netbird`](../tofu/netbird.md) is for — a rule from
`k0s` to `k0s` with `protocol = "all"` and no ports:

```hcl
rule {
  name          = "k0s to k0s, every protocol"
  action        = "accept"
  protocol      = "all"
  bidirectional = true
  sources       = [netbird_group.nodes.id]
  destinations  = [netbird_group.nodes.id]
}
```

Nothing asserts it server-side: NetBird has no policy tests, so a rule narrowed by mistake
applies cleanly and only fails in traffic. Re-check the
live policy before believing a cross-node networking bug is a node-local fault, and re-check it
in particular after any dashboard edit, which tofu will not know about until the next plan.

The failure is worth recognising by shape, because it does not look like a policy problem. Half
of all ClusterIP DNS answers time out while direct-to-pod-IP works, because CoreDNS runs one
pod per node and kube-proxy load-balances 50/50 — only the remote endpoint is unreachable.
Anything that resolves DNS at startup then fails intermittently or crashloops. The test:

```bash
# from a pod, against a pod on the *other* node
ping -c2 <remote pod IP>   # fails => overlay is dropping, check the all-protocol rule
```
