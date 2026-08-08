# NetBird's built-in group. Every peer is a member of it and it cannot be deleted, which is why
# it is looked up rather than declared — and why nothing below uses it as a policy *destination*
# without meaning "the whole network".
data "netbird_group" "all" {
  name = "All"
}

# The k0s nodes. Peers land here automatically: ansible/roles/netbird mints a setup key with
# this group in auto_groups, so membership follows the join and is never assigned by hand.
# The group is this module's equivalent of the old tag:futhark-node — policies, the service
# route and the DNS zone all target it. Its name is mirrored in
# ansible/inventory/group_vars/all/network.yml as mesh_node_group; changing it in one place
# only strands every node outside every rule.
resource "netbird_group" "nodes" {
  name = "futhark-nodes"

  # `peers` is Ansible's to fill, not this module's. Without this, a converge that adds a peer
  # leaves a diff here that the next apply would "correct" by emptying the group.
  lifecycle {
    ignore_changes = [peers]
  }
}

# The operator's own devices — laptop, phone. Empty here for the same reason: peers are added
# from the dashboard when they enrol, and this module only needs the group to exist so the SSH
# and internal-ingress rules have something to name that is narrower than "All".
resource "netbird_group" "admins" {
  name = "futhark-admins"

  lifecycle {
    ignore_changes = [peers]
  }
}
