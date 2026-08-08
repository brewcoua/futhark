# Two axes, deliberately. `node` is "a machine this repo provisions", `k0s` is "a machine that
# runs the cluster" — today every node is both, but the policies below target the workflow, not
# the fleet, so a future node that runs something else joins `node` and reaches nothing extra.
#
# ansible/roles/netbird puts a peer in both at join time, from the setup key's auto_groups:
# `node` from mesh_node_group, the workflow one from node.workflow in ansible/nodes/<host>/host.yml.
# Names are matched by string on that side, so a rename here strands every node outside every
# rule until it is renamed there too.
resource "netbird_group" "node" {
  name = "node"

  # `peers` is Ansible's to fill. Without this, a converge that adds a peer leaves a diff here
  # that the next apply would "correct" by emptying the group.
  lifecycle {
    ignore_changes = [peers]
  }
}

resource "netbird_group" "k0s" {
  name = "k0s"

  lifecycle {
    ignore_changes = [peers]
  }
}

# The operator's own devices — laptop, phone. Empty here: those peers enrol from the dashboard,
# and this module only needs the group to exist for the rules that name it.
resource "netbird_group" "admin" {
  name = "admin"

  lifecycle {
    ignore_changes = [peers]
  }
}
