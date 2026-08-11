# Every internal hostname (dash, logs, metrics, actual, …) is served by the same
# traefik-internal, so one wildcard covers all of them and a new internal app needs no apply
# here.
#
# The zone is NetBird's, not Bunny's: only peers get these answers, which is the point of the
# internal subdomain — off-mesh the name dead-ends. The public zone still resolves nothing under
# it; cert-manager only ever writes DNS-01 challenge records there (infra/cert-manager).
resource "netbird_dns_zone" "internal" {
  name                 = "internal"
  domain               = "${var.sub_internal}.${var.domain}"
  enabled              = true
  enable_search_domain = false
  distribution_groups  = [netbird_group.admin.id]
}

# An A record to the ingress node's own mesh address, where traefik-internal binds 443 with
# hostNetwork (infra/traefik-internal/app/helmrelease.yaml). A peer address needs no route: it is
# reachable by every peer the policies allow, which is why this module advertises no CIDR of its
# own. The address comes from refs.env, out of the `nodes` map roles/netbird writes after each
# join, so nothing here is maintained by hand.
resource "netbird_dns_record" "internal_wildcard" {
  zone_id = netbird_dns_zone.internal.id
  name    = "*.${netbird_dns_zone.internal.domain}"
  type    = "A"
  content = var.mesh_ip
  ttl     = 300
}
