# Declared in this module's refs.env and resolved out of ansible/nodes/kenaz/host.sops.yml at
# plan/apply time — that file is the canonical record, and the same one the netbird role writes
# node_mesh_ip back into after a mesh join. Not held in this module's secrets.sops.env: a
# second encrypted copy of the same address drifts silently, and it would also *win*, since
# `sops exec-env` runs after the refs are exported.
variable "kenaz_public_ip" {
  description = "kenaz's public IP — same value substituted into $${PUBLIC_IP} in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.kenaz_public_ip))
    error_message = "kenaz_public_ip must look like an IPv4 address."
  }
}

# Declared in refs.env and read from config/dns/dns.sops.yaml, the one place the domain is written
# down — Flux substitutes the same key into manifests. The zone this module manages is the
# domain's own public zone; internal names are NetBird's (tofu/netbird/dns.tf).
variable "domain" {
  description = "Base domain, e.g. example.eu."
  type        = string
}

# kenaz_mesh_ip was declared here but referenced by no resource in this module — ${MESH_IP} in
# infra/traefik-internal is substituted by Flux out of infra/substitutions/app/edge-ips.sops.yaml,
# never by tofu. Removed rather than wired up; add it back only alongside a consumer.
