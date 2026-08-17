# Looked up, not created: the zone already exists (the DNS-01 webhook in infra/cert-manager
# solves challenges against it) — creating a bunnynet_dns_zone here would duplicate it.
data "bunnynet_dns_zone" "this" {
  domain = var.domain
}

# One record per edge-exposed hostname — add one bunnynet_dns_record block per additional edge
# app as they land. auth.DOMAIN routes through traefik-edge on the edge node to infra/auth
# (Pocket ID), a Flux-managed workload pinned to that same node. See
# docs/src/conventions/ordering.md.
resource "bunnynet_dns_record" "auth" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "auth"
  type  = "A"
  value = var.edge_public_ip
  ttl   = 300

  lifecycle {
    prevent_destroy = true
  }
}

# git and ci both point at brokkr, not at the edge node: that host is outside the cluster and
# terminates its own TLS with a Traefik of its own. Its certificates are issued by TLS-ALPN-01 on
# 443, so unlike the cluster's DNS-01 flow nothing writes a challenge record into this zone for
# them, and these two A records are the only thing that has to exist here.
#
# Separate records rather than a wildcard for the same reason `auth` is its own record: a wildcard
# would resolve every unclaimed name under the domain to whichever host it pointed at.
resource "bunnynet_dns_record" "git" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "git"
  type  = "A"
  value = var.brokkr_public_ip
  ttl   = 300

  # This is the forge holding a mirror of this repository, and the record is how anyone reaches it
  # when the cluster is down. Destroying it is never the intent of an unrelated apply.
  lifecycle {
    prevent_destroy = true
  }
}

resource "bunnynet_dns_record" "ci" {
  zone  = data.bunnynet_dns_zone.this.id
  name  = "ci"
  type  = "A"
  value = var.brokkr_public_ip
  ttl   = 300

  lifecycle {
    prevent_destroy = true
  }
}

# Nothing resolves under the internal subdomain from here. NetBird answers those names to peers
# from a zone of its own (tofu/netbird/dns.tf); the only records this zone ever holds under it
# are cert-manager's DNS-01 challenges, written and deleted by the ACME solver.
