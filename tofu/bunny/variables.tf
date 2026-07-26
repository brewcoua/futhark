variable "kenaz_public_ip" {
  description = "kenaz's public IP — same value substituted into $${PUBLIC_IP} in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.kenaz_public_ip))
    error_message = "kenaz_public_ip must look like an IPv4 address."
  }
}

variable "kenaz_mesh_ip" {
  description = "kenaz's Tailscale mesh IP — vault.INT_DOMAIN resolves publicly to this CGNAT (100.64.0.0/10) address, reachable only from the tailnet. Same value substituted into $${MESH_IP} in infra/traefik-internal/app/helmrelease.yaml."
  type        = string
  validation {
    # Tailscale's CGNAT pool is 100.64.0.0/10 — second octet 64-127. Catches the two values
    # being swapped, which would silently publish kenaz's public IP internally and its CGNAT
    # address externally.
    condition     = can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.", var.kenaz_mesh_ip))
    error_message = "kenaz_mesh_ip must be a 100.64.0.0/10 Tailscale CGNAT address — got a value outside that range. Did kenaz_public_ip and kenaz_mesh_ip get swapped?"
  }
}
