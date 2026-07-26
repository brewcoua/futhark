terraform {
  required_version = ">= 1.7.0"
  required_providers {
    bunnynet = {
      source = "BunnyWay/bunnynet"
      # Patch-level only — see tofu/tailscale/provider.tf for why a 2-component "~>" is
      # looser than it looks on a 0.x provider.
      version = "~> 0.15.1"
    }
  }
}

# api_key comes from BUNNYNET_API_KEY — pass-cli run --env-file secrets.env resolves it before
# tofu ever sees it. See README.md.
provider "bunnynet" {}
