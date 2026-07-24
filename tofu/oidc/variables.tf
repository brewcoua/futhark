variable "openbao_namespace" {
  description = "OpenBao namespace this apply targets (e.g. node-kenaz), passed to the vault provider. Fixed per apply — see provider.tf."
  type        = string
}
