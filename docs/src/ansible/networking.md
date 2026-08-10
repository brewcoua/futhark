# Pod to mesh networking

Why a pod cannot reach a peer node's own mesh address without help, the two separate fixes that
make it work, and how to tell which one has broken. Read this before touching
`ansible/roles/netbird`.

> **Written against k0s and kube-router.** The cluster now runs k3s, whose default CNI is
> flannel with a VXLAN backend, not kube-router with IPIP. The decision this page starts from is
> unchanged and so is fix 2; fix 1 depends on the CNI installing a policy routing rule of its own,
> which flannel may not do at all. Check `ip rule` on a running node before trusting or removing
> anything under "1. Route lookup".

kubelet's `node-ip` is pinned to each node's NetBird mesh IP, on purpose: the Kubernetes API,
etcd and kubelet are then only ever bound to mesh addresses and are never publicly exposed.
Everything below follows from that one decision.

Because the nodes share no L2 segment, the CNI builds its own overlay between their mesh IPs to
carry cross-node pod-to-pod traffic: IPIP under kube-router, VXLAN under flannel. That has two
consequences, both of which break a pod dialing a peer node's **own** mesh address.

This is not a hypothetical case. `konnectivity-agent` does exactly that, dialing the controller's
`konnectivity-server` over the mesh, so while it is broken `kubectl exec`, `logs` and
`port-forward` are down cluster-wide.

Two paths leave a pod for another node, and they fail for different reasons, which is why the two
fixes below are not interchangeable:

```d2
direction: down

classes: {
  note: {
    style: {
      stroke: dimgray
      stroke-dash: 4
      fill: transparent
    }
  }
  noteline: {
    style: {
      stroke: dimgray
      stroke-dash: 4
    }
  }
}

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

fix1: "1. ip rule per peer /32 at mesh_route_priority\nkube-router's rule would send this into the tunnel\nwhose endpoint IS that address" { class: note }
fix2: "2. SNAT to the node's mesh IP\nthe WireGuard peer drops foreign source addresses,\nfailing as 'no route to host'" { class: note }
acl: "the mesh policy must pass every protocol\nor the IPIP tunnel blackholes silently" { class: note }

fix1 -> a.ts { class: noteline }
fix2 -> a.ts { class: noteline }
acl -> a.tun { class: noteline }
```

## 1. Routing

kube-router installs `from <node's pod /24> lookup 77` and puts the peer's mesh IP into table
77 pointing at its tunnel, so the packet is routed into the very tunnel whose transport
endpoint **is** that address.

The fix is one `ip rule` per peer at `mesh_route_priority`, matching only that peer's `/32` and
never the pod CIDR, so pod-to-pod overlay routing is untouched. It looks the peer up in
`mesh_route_table`, which the same script populates with a `<peer>/32 dev netbird0` route. That
table is ours and holds exactly what is written into it, rather than depending on where the VPN
client happens to install its own routes. NetBird keeps those in table 7120, with rules at
priorities 105 and 110, well clear of `mesh_route_priority`.

The priority is load-bearing whenever the CNI installs a rule of its own. kube-router's moved
before: 5209, then 99, then priority 9 as of kube-router v2.10.0. That last move silently shadowed this fix
at its old priority 10 and broke every mesh-peer-initiated connection into a pod, meaning backends
behind traefik-edge, which is hostNetwork and reaches them as the node's own mesh IP. It surfaced
as 502 Bad Gateway with no error anywhere else in the stack. Check `ip rule` on the node rather
than assuming, and re-check after a CNI bump.

## 2. Source address

The WireGuard peer drops packets whose source is not the node's own mesh address, as
anti-spoofing, so pod-sourced packets still die on egress even once the route is correct. They fail with
`no route to host`, which reads like a routing fault and is not one.

They have to be masqueraded to the node's mesh IP. Nothing else does this: kube-proxy's
`KUBE-POSTROUTING` only masquerades service traffic carrying the `0x4000` mark, and NetBird
only masquerades traffic for the network routes it advertises, which pod-to-peer traffic is
not.

The SNAT is scoped to peer `/32`s rather than the whole `mesh_cidr` on purpose. Pods get to reach
cluster nodes, such as konnectivity-agent to konnectivity-server and vmagent to traefik on the
mesh IP, without inheriting the node's own reach across the entire mesh.

All three rules live in `ansible/roles/netbird/templates/futhark-mesh-routes.sh.j2`, re-applied
by a systemd oneshot because neither `ip rule`, a route in a custom table, nor iptables state
survives a reboot.

The script reads the peer set out of `netbird status --json` each time it runs, rather than
having Ansible resolve peer addresses and bake them in. A peer re-registering onto a different
mesh address would otherwise strand these rules until someone ran Ansible again, over the very
mesh that is now half broken. It tears down everything it owns and rebuilds from the current peer
set, so a peer that has gone away leaves nothing behind. The SNAT rules sit in their own
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

IPIP solves the source-address half for cross-node **pod-to-pod** traffic on its own. The outer
header is sourced from the node's own mesh IP, so it never presents a foreign source to the mesh
client. But the overlay only carries traffic at all if the mesh policy permits it.

NetBird policy rules name a protocol: `tcp`, `udp`, `icmp`, `netbird-ssh`, or `all`. IPIP is IP
protocol 4, so only `all` passes it; flannel's VXLAN is UDP 8472, which a narrower rule could
carry but only by writing the CNI's port into the access model. Anything narrower and cross-node
pod-to-pod blackholes: the route is correct, the tunnel is `UP`, nothing is logged, and every
packet vanishes.

That is what `netbird_policy.k8s` in [`tofu/netbird`](../tofu/netbird.md) is for: a rule from
`k8s` to `k8s` with `protocol = "all"` and no ports.

```hcl
rule {
  name          = "k8s to k8s, every protocol"
  action        = "accept"
  protocol      = "all"
  bidirectional = true
  sources       = [netbird_group.k8s.id]
  destinations  = [netbird_group.k8s.id]
}
```

Nothing asserts it server-side: NetBird has no policy tests, so a rule narrowed by mistake
applies cleanly and only fails in traffic. Re-check the
live policy before believing a cross-node networking bug is a node-local fault, and re-check it
in particular after any dashboard edit, which tofu will not know about until the next plan.

The failure is worth recognising by shape, because it does not look like a policy problem. Half
of all ClusterIP DNS answers time out while direct-to-pod-IP works, because CoreDNS runs one
pod per node and kube-proxy load-balances 50/50, so only the remote endpoint is unreachable.
Anything that resolves DNS at startup then fails intermittently or crashloops. The test:

```bash
# from a pod, against a pod on the *other* node
ping -c2 <remote pod IP>   # fails => overlay is dropping, check the all-protocol rule
```
