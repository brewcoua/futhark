# Looked up, not created: the zone already exists (the DNS-01 webhook in infra/cert-manager
# solves challenges against it) — creating a bunnynet_dns_zone here would duplicate it.
data "bunnynet_dns_zone" "this" {
  domain = var.domain
}

# One record per edge-exposed hostname — add one bunnynet_dns_record block per additional edge
# app as they land. auth.DOMAIN routes through kenaz/traefik-edge to infra/auth (Pocket ID),
# a Flux-managed workload pinned to ogma — see docs/src/conventions/ordering.md.
resource "bunnynet_dns_record" "auth" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "auth"
  type  = "A"
  value = var.kenaz_public_ip
  ttl   = 300

  lifecycle {
    prevent_destroy = true
  }
}

# Nothing resolves under the internal subdomain from here. NetBird answers those names to peers
# from a zone of its own (tofu/netbird/dns.tf); the only records this zone ever holds under it
# are cert-manager's DNS-01 challenges, written and deleted by the ACME solver.
