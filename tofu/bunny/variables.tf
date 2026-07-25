variable "kenaz_public_ip" {
  description = "kenaz's public IP — same value that fills REPLACE_WITH_PUBLIC_IP in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
}

variable "kenaz_mesh_ip" {
  description = "kenaz's Tailscale mesh IP — vault.INT_DOMAIN resolves publicly to this CGNAT (100.64.0.0/10) address, reachable only from the tailnet. Same value that fills REPLACE_WITH_MESH_IP in infra/traefik-internal/app/helmrelease.yaml."
  type        = string
}
