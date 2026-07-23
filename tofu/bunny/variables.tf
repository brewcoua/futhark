variable "domain" {
  description = "Base public domain (matches infra/_components/domain's DOMAIN)."
  type        = string
}

variable "kenaz_public_ip" {
  description = "kenaz's public IP — same value that fills REPLACE_WITH_PUBLIC_IP in infra/traefik-edge/app/helmrelease.yaml."
  type        = string
}

variable "ogma_public_ip" {
  description = "ogma's public IP — Pocket ID/Traefik run there directly, decoupled from k0s."
  type        = string
}
