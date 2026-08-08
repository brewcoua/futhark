# NetBird is deny-by-default: a peer reaches nothing it has no accept rule for. These three
# rules are therefore the whole access model — and a fresh account's shipped "Default" policy
# (All -> All, every protocol) silently overrides all of it until deleted. Delete it once, by
# hand, at bootstrap. See docs/src/tofu/netbird.md.
#
# Keep this file free of identifying values — it is committed to a public repo. Group names and
# CIDRs are architecture and fine; user emails, peer addresses and local usernames are not.

# Cross-node pod traffic. k0s's CNI (kube-router) carries pod-to-pod between nodes in an IPIP
# tunnel whose endpoints are the nodes' mesh addresses, so this rule has to pass IP protocol 4,
# not just TCP/UDP/ICMP — which is what `protocol = "all"` is for and why it is not narrowed to
# ports. Getting the equivalent wrong once took the cluster down and presented as half of all
# ClusterIP DNS timing out, because CoreDNS runs one pod per node behind a 50/50 balance.
# See docs/src/ansible/networking.md.
resource "netbird_policy" "k0s" {
  name    = "k0s mesh"
  enabled = true

  rule {
    name          = "k0s to k0s, every protocol"
    action        = "accept"
    protocol      = "all"
    bidirectional = true
    enabled       = true
    sources       = [netbird_group.k0s.id]
    destinations  = [netbird_group.k0s.id]
  }
}

# The operator's devices reaching the cluster: internal ingress over netbird_route.k0s_services,
# and the k0s API. One direction only — nothing on the cluster needs to dial a laptop.
resource "netbird_policy" "admin" {
  name    = "admin to k0s"
  enabled = true

  rule {
    name          = "admin -> k0s"
    action        = "accept"
    protocol      = "all"
    bidirectional = false
    enabled       = true
    sources       = [netbird_group.admin.id]
    destinations  = [netbird_group.k0s.id]
  }

  # A destroy here takes the operator's own access to the cluster with it.
  lifecycle {
    prevent_destroy = true
  }
}

# Matches `netbird up --allow-server-ssh` in ansible/roles/netbird: without the flag the rule
# matches and the peer still refuses the session. Targets `node`, not `k0s` — SSH is how a
# machine is administered, whatever it runs.
#
# authorized_groups is deliberately unset: set, it whitelists *local* usernames, which are
# identifying and would have to come in as a variable to stay out of this file. Unset means
# every local account is reachable, gated by the account's own SSH authorized_keys and by
# membership of `admin`.
resource "netbird_policy" "ssh" {
  name    = "admin ssh to nodes"
  enabled = true

  rule {
    name          = "admin -> node"
    action        = "accept"
    protocol      = "netbird-ssh"
    bidirectional = false
    enabled       = true
    sources       = [netbird_group.admin.id]
    destinations  = [netbird_group.node.id]
  }

  lifecycle {
    prevent_destroy = true
  }
}
