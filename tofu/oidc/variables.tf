# Identifying, not secret — set as TF_VAR_infisical_project_id in this module's SOPS-encrypted
# secrets.sops.env, like every other value that ties this public repo to a real account.
variable "infisical_project_id" {
  description = "Infisical project (workspace) ID that infisical_secret writes into."
  type        = string
  validation {
    condition     = length(var.infisical_project_id) > 0
    error_message = "infisical_project_id must not be empty."
  }
}

# Declared in refs.env and read from infra/substitutions/app/int-domain.sops.yaml, the Secret
# Flux substitutes into manifests as ${INT_DOMAIN}. Flux owns it; tofu/bunny reads the same key.
# One copy, not three.
variable "int_domain" {
  description = "The internal wildcard's base domain, e.g. example.eu."
  type        = string
}
