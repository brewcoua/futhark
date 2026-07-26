terraform {
  required_version = ">= 1.7.0"
  required_providers {
    pocketid = {
      source = "Trozz/pocketid"
      # Patch-level only — see tofu/tailscale/provider.tf for why a 2-component "~>" is
      # looser than it looks on a 0.x provider. Doubly so for a third-party provider that
      # mints credentials.
      version = "~> 0.1.8"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# base_url/api_token come from POCKETID_BASE_URL / POCKETID_API_TOKEN — pass-cli run
# --env-file secrets.env resolves them before tofu ever sees them. See docs/src/tofu/oidc.md.
provider "pocketid" {}

# token comes from VAULT_TOKEN, resolved the same way as the pocketid provider above. No
# VAULT_CACERT: vault.INT_DOMAIN is now served through the Ingress on 443 with the same
# publicly-trusted wildcard LE cert every other internal app uses, not OpenBao's own
# self-signed listener cert (dropped along with nodes/ogma.podman — see infra/openbao/app/
# configmap.yaml). address is set explicitly (not via VAULT_ADDR) because it's a required
# argument with no built-in default — leaving it env-only breaks `tofu validate` in the
# pre-commit tofu-validate hook, which runs without secrets.env loaded. It isn't secret anyway,
# so deriving it from domain.env (see clients.tf's local.int_domain) is fine to commit.
# namespace is fixed per apply of this module — see variables.tf and docs/src/tofu/oidc.md.
provider "vault" {
  address   = "https://vault.${local.int_domain}"
  namespace = var.openbao_namespace
}
