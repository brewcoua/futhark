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

# Declared in refs.env and read from config/dns/dns.sops.yaml, the one place the domain and its
# subdomain labels are written down. One copy, not three.
variable "domain" {
  description = "Base domain, e.g. example.eu."
  type        = string
}

variable "sub_internal" {
  description = "Subdomain label for internal services, e.g. in."
  type        = string
}
