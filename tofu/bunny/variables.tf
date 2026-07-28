# Declared in this module's refs.env and resolved out of ansible/nodes/kenaz/host.sops.yml at
# plan/apply time — that file is the canonical record, and the same one the tailscale role writes
# node_mesh_ip back into after a tailnet join. Not held in this module's secrets.sops.env: a
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

# The tailnet's MagicDNS domain, target of the internal wildcard CNAME in dns.tf. Declared in
# refs.env and read from ansible/inventory/group_vars/all/secrets.sops.yml, which owns it because
# roles/tailscale needs it on every node. tofu/tailscale's TAILSCALE_TAILNET reads the same key,
# so there is one copy rather than three.
variable "tailnet_domain" {
  description = "The tailnet's MagicDNS domain, e.g. example-tailnet.ts.net."
  type        = string
  validation {
    condition     = endswith(var.tailnet_domain, ".ts.net")
    error_message = "tailnet_domain must be a MagicDNS domain ending in .ts.net."
  }
}

# Declared in refs.env and read from infra/substitutions/app/int-domain.sops.yaml, the Secret Flux
# substitutes into manifests as ${INT_DOMAIN}. Flux owns it; tofu/oidc reads the same key. Tofu
# and Flux decrypt through different key paths, but both reach this file, so one copy suffices.
variable "int_domain" {
  description = "The internal wildcard's base domain, e.g. example.eu."
  type        = string
}

# kenaz_mesh_ip was declared here but referenced by no resource in this module — ${MESH_IP} in
# infra/traefik-internal is substituted by Flux out of infra/substitutions/app/edge-ips.sops.yaml,
# never by tofu. Removed rather than wired up; add it back only alongside a consumer.
