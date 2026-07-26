terraform {
  required_version = ">= 1.7.0"
  required_providers {
    tailscale = {
      source = "tailscale/tailscale"
      # Patch-level only — a 2-component "~> 0.17" allows any 0.x release (Terraform's ~>
      # only fixes components to the left of the last one given), which is not what a 0.x
      # provider's own semver convention promises: minor bumps there are breaking.
      version = "~> 0.29.2"
    }
  }
}

# oauth_client_id/oauth_client_secret/tailnet come from TAILSCALE_OAUTH_CLIENT_ID,
# TAILSCALE_OAUTH_CLIENT_SECRET and TAILSCALE_TAILNET — pass-cli run --env-file secrets.env
# resolves them before tofu ever sees them. The tailnet name is identifying, hence a pointer
# rather than a literal. See docs/src/tofu/tailscale.md.
provider "tailscale" {}
