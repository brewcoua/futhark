# Looked up, not created: the zone already exists (it's what cert-manager's DNS-01 webhook
# already points at for infra/cert-manager) — creating a bunnynet_dns_zone here would duplicate it.
data "bunnynet_dns_zone" "this" {
  domain = var.domain
}

# One record per edge-exposed hostname. auth.DOMAIN is the first (infra/authentik) — add one
# bunnynet_dns_record block per additional edge app as they land.
resource "bunnynet_dns_record" "auth" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "auth"
  type  = "A"
  value = var.kenaz_public_ip
  ttl   = 300
}
