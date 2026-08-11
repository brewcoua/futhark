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

# The ingress node's mesh address, for the internal wildcard record in dns.tf. Identifying, so it
# comes from refs.env rather than in the clear like the CIDR below.
variable "mesh_ip" {
  description = "Mesh address of the node traefik-internal binds on."
  type        = string
}

# The account's own network range, read from the file Ansible already uses it from rather than
# spelled a second time here: it has to be the same range Ansible trusts in firewalld and fail2ban.
# Not identifying, so it is read in the clear rather than through refs.env.
locals {
  mesh_cidr = regex(
    "(?m)^mesh_cidr: (\\S+)$",
    file("${path.module}/../../ansible/inventory/group_vars/all/network.yml")
  )[0]
}
