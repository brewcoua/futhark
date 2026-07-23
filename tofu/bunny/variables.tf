variable "kenaz_public_ip" {
  description = "kenaz's public IP — same value that fills REPLACE_WITH_PUBLIC_IP in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
}

variable "ogma_public_ip" {
  description = "ogma's public IP — Pocket ID/Traefik run there directly, decoupled from k0s."
  type        = string
}

variable "ogma_mesh_ip" {
  description = "ogma's Tailscale mesh IP — vault.INT_DOMAIN resolves publicly to this CGNAT (100.64.0.0/10) address, reachable only from the tailnet."
  type        = string
}
