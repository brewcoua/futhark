# DOMAIN is Kustomize's source of truth too (config/domain/domain.env) — read straight from
# that file so it never drifts.
locals {
  domain_env_file = file("${path.module}/../../config/domain/domain.env")
  domain          = regex("(?m)^DOMAIN=(.*)$", local.domain_env_file)[0]
}

# Looked up, not created: the zone already exists (the DNS-01 webhook in infra/cert-manager
# solves challenges against it) — creating a bunnynet_dns_zone here would duplicate it.
#
# INT_DOMAIN's zone is deliberately absent. It exists in Bunny and is still needed there for
# DNS-01, but this module holds no record in it: internal names are answered by NetBird's own
# zone now (tofu/netbird/dns.tf), not by a public CNAME into the mesh.
data "bunnynet_dns_zone" "this" {
  domain = local.domain
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

# The internal wildcard used to live here, as a CNAME into the tailnet's MagicDNS. It moved to
# tofu/netbird/dns.tf: NetBird serves INT_DOMAIN to peers from a zone of its own, so the public
# hop is no longer needed to keep the name mesh-only.
