# Every internal hostname (dash, logs, metrics, actual, …) is served by the same
# traefik-internal, so one wildcard covers all of them and an internal app landing needs no
# apply here.
#
# The zone is NetBird's, not Bunny's: only peers get these answers, which is the whole point of
# the internal domain — off-mesh the name dead-ends. INT_DOMAIN's Bunny zone still exists and is
# still needed, but for DNS-01 only (infra/cert-manager solves the wildcard cert's challenge
# there); the wildcard CNAME that used to live in tofu/bunny is gone, because that indirection
# only existed to reach a MagicDNS name.
resource "netbird_dns_zone" "internal" {
  name                 = "internal"
  domain               = var.int_domain
  enabled              = true
  enable_search_domain = false
  distribution_groups  = [data.netbird_group.all.id]
}

# An A record to the Service's ClusterIP, reachable through netbird_route.k0s_services. The
# address is read out of the HelmRelease that pins it (see variables.tf) rather than written
# twice — but it does have to be pinned there, since a wildcard DNS record cannot follow an
# address Kubernetes reassigns on every reinstall.
resource "netbird_dns_record" "internal_wildcard" {
  zone_id = netbird_dns_zone.internal.id
  name    = "*.${var.int_domain}"
  type    = "A"
  content = local.traefik_internal_ip
  ttl     = 300
}
