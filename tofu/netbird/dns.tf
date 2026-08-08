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

# An A record to the Service's ClusterIP, reachable through netbird_route.k0s_services. The
# address is read out of the HelmRelease that pins it (see variables.tf) rather than written
# twice — but it does have to be pinned there, since a wildcard DNS record cannot follow an
# address Kubernetes reassigns on every reinstall.
resource "netbird_dns_record" "internal_wildcard" {
  zone_id = netbird_dns_zone.internal.id
  name    = "*.${netbird_dns_zone.internal.domain}"
  type    = "A"
  content = local.traefik_internal_ip
  ttl     = 300
}
