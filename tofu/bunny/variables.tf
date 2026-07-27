# Declared in this module's node-refs.env and resolved out of ansible/nodes/kenaz/host.sops.yml
# at plan/apply time — that file is the canonical record, and the same one the tailscale role
# writes node_mesh_ip back into after a tailnet join. Not held in this module's
# secrets.sops.env: a second encrypted copy of the same address drifts silently, and both paths
# seal to the same operator key anyway (.sops.yaml, `(ansible|tofu)/.*\.sops\.(ya?ml|env)$`).
variable "kenaz_public_ip" {
  description = "kenaz's public IP — same value substituted into $${PUBLIC_IP} in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.kenaz_public_ip))
    error_message = "kenaz_public_ip must look like an IPv4 address."
  }
}

# The tailnet's MagicDNS domain, target of the internal wildcard CNAME in dns.tf. Held in this
# module's secrets.sops.env, not node-refs.env: that path resolves node addresses out of
# ansible/nodes/<node>/host.sops.yml and this is neither a node nor an address. tofu/tailscale's
# TAILSCALE_TAILNET is the same value — the one place in this repo a second encrypted copy is
# unavoidable, so change both together.
variable "tailnet_domain" {
  description = "The tailnet's MagicDNS domain, e.g. example-tailnet.ts.net."
  type        = string
  validation {
    condition     = endswith(var.tailnet_domain, ".ts.net")
    error_message = "tailnet_domain must be a MagicDNS domain ending in .ts.net."
  }
}

# kenaz_mesh_ip was declared here but referenced by no resource in this module — ${MESH_IP} in
# infra/traefik-internal is substituted by Flux out of infra/edge-ips/app/edge-ips.sops.yaml,
# never by tofu. Removed rather than wired up; add it back only alongside a consumer.
