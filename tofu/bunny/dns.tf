# Same source of truth as config/domain/domain.env (Kustomize's DOMAIN/INT_DOMAIN,
# used across Flux-managed apps) and ansible's `domain`/`int_domain` vars — read straight from
# that file so nothing drifts.
locals {
  domain_env_file = file("${path.module}/../../config/domain/domain.env")
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
# app as they land. auth.DOMAIN routes through kenaz/traefik-edge to infra/auth (Pocket ID),
# a Flux-managed workload pinned to ogma — see docs/src/conventions/ordering.md
# (openbao -> external-secrets -> auth -> rest).
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

# Every internal hostname (dash, headlamp, logs, metrics, actual, …) is served by the same
# traefik-internal, which the tailscale operator exposes as one tailnet device named "internal"
# (the tailscale.com/hostname annotation in infra/traefik-internal/app/helmrelease.yaml). So one
# wildcard covers all of them, and an internal app landing needs no apply here.
#
# A CNAME to the MagicDNS name rather than an A record to the device's tailnet IP: that IP is
# assigned by the operator and recorded nowhere in this repo, so an A record would drift exactly
# the way edge-ips' MESH_IP did. Only tailnet resolvers answer a *.ts.net name — off-tailnet
# this record dead-ends, which is the point of the internal domain.
resource "bunnynet_dns_record" "internal_wildcard" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "*.${local.int_domain_prefix}"
  type  = "CNAME"
  value = "internal.${var.tailnet_domain}"
  ttl   = 300
}
