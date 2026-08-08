# Declared in refs.env and read from infra/substitutions/app/int-domain.sops.yaml, the Secret Flux
# substitutes into manifests as ${INT_DOMAIN}. Flux owns it; tofu/bunny reads the same key, so
# the NetBird zone and the Bunny zone can never name different domains.
variable "int_domain" {
  description = "The internal wildcard's base domain, e.g. example.eu."
  type        = string
}

# Neither of the two values below is identifying — they are k0s defaults and a cluster-internal
# address — so they are read from their canonical files in the clear rather than through
# refs.env, the same way tofu/bunny reads DOMAIN out of config/domain/domain.env. A second
# spelling of either is a second thing to get wrong: the route has to name the CIDR k0s actually
# uses, and the DNS record has to name the address the Service actually holds.
locals {
  service_cidr = regex(
    "(?m)^k0s_service_cidr: (\\S+)$",
    file("${path.module}/../../ansible/inventory/group_vars/all/network.yml")
  )[0]

  traefik_internal_ip = regex(
    "(?m)^\\s+clusterIP: (\\S+)$",
    file("${path.module}/../../infra/traefik-internal/app/helmrelease.yaml")
  )[0]
}
