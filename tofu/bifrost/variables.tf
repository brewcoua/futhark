# Identifying, not secret — set as TF_VAR_infisical_project_id in this module's `tofu.bifrost`
# section of config/sops/ops.sops.yaml, like every other value that ties this public repo to a real
# account.
variable "infisical_project_id" {
  description = "Infisical project (workspace) ID that infisical_secret writes into."
  type        = string
  validation {
    condition     = length(var.infisical_project_id) > 0
    error_message = "infisical_project_id must not be empty."
  }
}
