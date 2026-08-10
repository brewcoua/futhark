# Declared in this module's refs.env and resolved out of the `nodes` map in config/sops/ops.sops.yaml
# at plan/apply time — that map is the canonical record, and the same one the netbird role writes
# mesh_ip back into after a mesh join. Not held in this module's own `tofu.bunny` section: a
# second encrypted copy of the same address drifts silently, and it would also *win*, since a
# module's own values are exported after the refs.
variable "edge_public_ip" {
  description = "The edge node's public IP. Same value substituted into $${PUBLIC_IP} in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.edge_public_ip))
    error_message = "edge_public_ip must look like an IPv4 address."
  }
}

# Declared in refs.env and read from config/sops/cluster.sops.yaml, the one place the domain is written
# down — Flux substitutes the same key into manifests. The zone this module manages is the
# domain's own public zone; internal names are NetBird's (tofu/netbird/dns.tf).
variable "domain" {
  description = "Base domain, e.g. example.eu."
  type        = string
}

# kenaz_mesh_ip was declared here but referenced by no resource in this module — ${MESH_IP} in
# infra/traefik-internal is substituted by Flux out of config/sops/cluster.sops.yaml, never by tofu. Removed rather than wired up; add it back only alongside a consumer.
