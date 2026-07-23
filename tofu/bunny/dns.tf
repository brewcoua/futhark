# Same source of truth as infra/_components/domain/domain.env (Kustomize's DOMAIN/INT_DOMAIN,
# used across Flux-managed apps) and ansible's `domain`/`int_domain` vars — read straight from
# that file so nothing drifts.
locals {
  domain_env_file = file("${path.module}/../../infra/_components/domain/domain.env")
  domain          = regex("(?m)^DOMAIN=(.*)$", local.domain_env_file)[0]
  int_domain      = regex("(?m)^INT_DOMAIN=(.*)$", local.domain_env_file)[0]
  # e.g. INT_DOMAIN "local.brewen.dev" against DOMAIN "brewen.dev" -> "local", the record name
  # prefix relative to the zone.
  int_domain_prefix = trimsuffix(local.int_domain, ".${local.domain}")
}

# Looked up, not created: the zone already exists (it's what cert-manager's DNS-01 webhook
# already points at for infra/cert-manager) — creating a bunnynet_dns_zone here would duplicate it.
data "bunnynet_dns_zone" "this" {
  domain = local.domain
}

# One record per edge-exposed hostname — add one bunnynet_dns_record block per additional edge
# app as they land. auth.DOMAIN points at ogma directly (Pocket ID + its own Traefik), not
# kenaz/traefik-edge, so auth survives a k0s outage.
resource "bunnynet_dns_record" "auth" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "auth"
  type  = "A"
  value = var.ogma_public_ip
  ttl   = 300
}

# vault.INT_DOMAIN — resolves publicly to ogma's Tailscale mesh IP (CGNAT, 100.64.0.0/10), so
# only reachable from the tailnet. Routed by nodes/ogma.podman's Traefik (tailnet-only entryPoint,
# TLS passthrough) to OpenBao — see nodes/ogma.podman/README.md.
resource "bunnynet_dns_record" "vault" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "vault.${local.int_domain_prefix}"
  type  = "A"
  value = var.ogma_mesh_ip
  ttl   = 300
}
