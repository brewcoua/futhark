# NetBird is deny-by-default: a peer reaches nothing it has no accept rule for. That makes the
# policies below the whole access model, and it makes a fresh account's shipped "Default"
# policy (All -> All, every protocol) load-bearing until it is deleted — delete it once, by
# hand, at bootstrap, or the rules here describe an openness that is not actually enforced.
# See docs/src/tofu/netbird.md.
#
# Keep this file free of identifying values — it is committed to a public repo. Group names and
# CIDRs are architecture and fine; user emails, peer addresses and local usernames are not.

# The unrestricted baseline, carried over from the tailnet policy this replaced. Narrow it
# before it matters: with it enabled, the two rules below add nothing but documentation of
# intent, and only start enforcing anything once this one is gone.
resource "netbird_policy" "baseline" {
  name    = "baseline"
  enabled = true

  rule {
    name          = "everything to everything"
    action        = "accept"
    protocol      = "all"
    bidirectional = true
    enabled       = true
    sources       = [data.netbird_group.all.id]
    destinations  = [data.netbird_group.all.id]
  }

  # A destroy here takes the operator's own access with it.
  lifecycle {
    prevent_destroy = true
  }
}

# Cross-node pod traffic. k0s's CNI (kube-router) carries pod-to-pod between nodes in an IPIP
# tunnel whose endpoints are the nodes' mesh addresses, so this rule has to pass IP protocol 4,
# not just TCP/UDP/ICMP — which is exactly what `protocol = "all"` is for and why it is not
# narrowed to ports. The tailnet policy this replaced needed an explicit `ip-in-ip:*` grant for
# the same reason; getting it wrong there took the cluster down once and presented as half of
# all ClusterIP DNS timing out, because CoreDNS runs one pod per node behind a 50/50 balance.
# See docs/src/ansible/networking.md.
resource "netbird_policy" "nodes" {
  name    = "futhark-nodes mesh"
  enabled = true

  rule {
    name          = "node to node, every protocol"
    action        = "accept"
    protocol      = "all"
    bidirectional = true
    enabled       = true
    sources       = [netbird_group.nodes.id]
    destinations  = [netbird_group.nodes.id]
  }
}

# Matches `netbird up --allow-server-ssh` in ansible/roles/netbird. NetBird's SSH is its own
# protocol rather than a separate policy document, so unlike the tailnet's `ssh` block it is
# reached and revoked the same way as everything else here.
#
# authorized_groups is deliberately unset: set, it whitelists *local* usernames, which are
# identifying and would have to come in as a variable to stay out of this file. Unset means
# every local account is reachable, gated by the account's own SSH authorized_keys and by
# membership of futhark-admins.
resource "netbird_policy" "ssh" {
  name    = "admin ssh to nodes"
  enabled = true

  rule {
    name          = "futhark-admins -> futhark-nodes"
    action        = "accept"
    protocol      = "netbird-ssh"
    bidirectional = false
    enabled       = true
    sources       = [netbird_group.admins.id]
    destinations  = [netbird_group.nodes.id]
  }

  lifecycle {
    prevent_destroy = true
  }
}
