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
    infisical = {
      source  = "Infisical/infisical"
      version = "~> 0.15"
    }
  }
}

# base_url/api_token come from POCKETID_BASE_URL / POCKETID_API_TOKEN — POCKETID_BASE_URL from
# this module's SOPS-encrypted secrets.sops.env, POCKETID_API_TOKEN injected by `bws run`. See
# docs/src/tofu/oidc.md.
provider "pocketid" {}

# eu.infisical.com is a separate data region, not a mirror of app.infisical.com — pointing at
# the wrong one authenticates against a tenant that does not have this project. host is set
# explicitly rather than left to the provider's default so `tofu validate` in the pre-commit
# hook works with nothing loaded, and it isn't secret anyway.
#
# The universal auth block reads INFISICAL_UNIVERSAL_AUTH_CLIENT_ID and
# INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET, injected by `bws run`. This is the `tofu-writer`
# machine identity — write on /nodes/kenaz/actual only, deliberately not the read-only identity
# the cluster uses.
provider "infisical" {
  host = "https://eu.infisical.com"
  # Attribute assignment, not a block — the provider models auth as a nested object type, so
  # `auth { universal {} }` is a syntax error. The empty universal object is deliberate: it
  # selects universal auth and leaves both credentials to their environment variables.
  auth = {
    universal = {}
  }
}
