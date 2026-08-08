# Account-wide settings, which NetBird would otherwise leave at defaults that both matter here:
# a random /16 out of 100.64.0.0/10 for peer addresses, and netbird.cloud as the peer domain.
#
# The peer domain is what `<hostname>.<domain>` resolves to for every peer, and it is what
# ansible/inventory/group_vars/all/main.yml dials as ansible_host. NetBird refuses a custom DNS
# zone that conflicts with it, which is why the internal zone in dns.tf sits under a different
# label of the same domain rather than under this one.
#
# This is a singleton — one per account, and the provider writes the whole settings object. Any
# field left unset here is set from this resource's own defaults, not from whatever the
# dashboard currently holds, so change settings here rather than there.
#
# IPv6 overlay addressing (NetBird v0.71+, an account IPv6 prefix plus the groups it applies to)
# has no field in provider 0.0.9. Enable it from the dashboard if wanted; nothing in this repo
# needs it.
resource "netbird_account_settings" "this" {
  dns_domain    = "${var.sub_nodes}.${var.domain}"
  network_range = local.mesh_cidr
}
