terraform {
  required_version = ">= 1.7.0"
  required_providers {
    pocketid = {
      source  = "Trozz/pocketid"
      version = "~> 0.1"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# base_url/api_token come from POCKETID_BASE_URL / POCKETID_API_TOKEN — pass-cli run
# --env-file secrets.env resolves them before tofu ever sees them. See README.md.
provider "pocketid" {}

# token/ca_cert come from VAULT_TOKEN / VAULT_CACERT, resolved the same way as the pocketid
# provider above. address is set explicitly (not via VAULT_ADDR) because it's a required
# argument with no built-in default — leaving it env-only breaks `tofu validate` in the
# pre-commit tofu-validate hook, which runs without secrets.env loaded. It isn't secret anyway,
# so deriving it from domain.env (see clients.tf's local.int_domain) is fine to commit.
# namespace is fixed per apply of this module — see variables.tf and README.md.
provider "vault" {
  address   = "https://vault.${local.int_domain}:8200"
  namespace = var.openbao_namespace
}
