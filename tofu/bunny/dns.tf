# DOMAIN is Kustomize's source of truth too (config/domain/domain.env) — read straight from
# that file so it never drifts. INT_DOMAIN isn't in that file: it's SOPS-encrypted (see
# var.int_domain), so it comes in as a Tofu variable instead.
locals {
  domain_env_file = file("${path.module}/../../config/domain/domain.env")
  domain          = regex("(?m)^DOMAIN=(.*)$", local.domain_env_file)[0]
}

# Looked up, not created: both zones already exist (the same DNS-01 webhook in
# infra/cert-manager solves challenges on either) — creating a bunnynet_dns_zone here would
# duplicate them. DOMAIN and INT_DOMAIN are unrelated apex domains, not the same zone, so each
# gets its own lookup.
data "bunnynet_dns_zone" "this" {
  domain = local.domain
}

data "bunnynet_dns_zone" "internal" {
  domain = var.int_domain
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
#
# Name is the bare wildcard "*": INT_DOMAIN is its own zone apex (not a subdomain of DOMAIN),
# so there's no prefix to compute.
resource "bunnynet_dns_record" "internal_wildcard" {
  zone  = data.bunnynet_dns_zone.internal.id
  name  = "*"
  type  = "CNAME"
  value = "internal.${var.tailnet_domain}"
  ttl   = 300
}
