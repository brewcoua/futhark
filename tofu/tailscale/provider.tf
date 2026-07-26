terraform {
  required_version = ">= 1.7.0"
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }
}

# oauth_client_id/oauth_client_secret/tailnet come from TAILSCALE_OAUTH_CLIENT_ID,
# TAILSCALE_OAUTH_CLIENT_SECRET and TAILSCALE_TAILNET — pass-cli run --env-file secrets.env
# resolves them before tofu ever sees them. The tailnet name is identifying, hence a pointer
# rather than a literal. See README.md.
provider "tailscale" {}
