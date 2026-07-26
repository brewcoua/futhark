variable "openbao_namespace" {
  description = "OpenBao namespace this apply targets (e.g. node-kenaz), passed to the vault provider. Fixed per apply — see provider.tf."
  type        = string
  validation {
    condition     = length(var.openbao_namespace) > 0
    error_message = "openbao_namespace must not be empty — this selects which OpenBao namespace vault_kv_secret_v2 writes into."
  }
}
