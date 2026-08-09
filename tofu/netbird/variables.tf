# The one base domain. Declared in refs.env and read from config/sops/cluster.sops.yaml, the Secret
# Flux also substitutes into manifests — so the NetBird peer domain, the internal zone and every
# Ingress host are the same decision made once. See docs/src/conventions/domains.md.
variable "domain" {
  description = "Base domain, e.g. example.eu."
  type        = string
}

# Label only, not a full domain: the zone below is "<sub_internal>.<domain>".
variable "sub_internal" {
  description = "Subdomain label for internal services, e.g. in."
  type        = string
}

variable "sub_nodes" {
  description = "Subdomain label NetBird answers peer names under, e.g. n."
  type        = string
}

# None of the three below is identifying — two k0s defaults and a cluster-internal address — so
# they are read from their canonical files in the clear rather than through refs.env. A second
# spelling of any of them is a second thing to get wrong: the route has to name the CIDR k0s
# actually uses, the DNS record the address the Service actually holds, and the account's
# network range the CIDR Ansible trusts in firewalld and fail2ban.
locals {
  network_yml = file("${path.module}/../../ansible/inventory/group_vars/all/network.yml")

  mesh_cidr    = regex("(?m)^mesh_cidr: (\\S+)$", local.network_yml)[0]
  service_cidr = regex("(?m)^k0s_service_cidr: (\\S+)$", local.network_yml)[0]

  traefik_internal_ip = regex(
    "(?m)^\\s+clusterIP: (\\S+)$",
    file("${path.module}/../../infra/traefik-internal/app/helmrelease.yaml")
  )[0]
}
