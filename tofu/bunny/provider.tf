terraform {
  required_version = ">= 1.7.0"
  required_providers {
    bunnynet = {
      source  = "BunnyWay/bunnynet"
      version = "~> 0.15"
    }
  }
}

# api_key comes from BUNNYNET_API_KEY — pass-cli run --env-file secrets.env resolves it before
# tofu ever sees it. See README.md.
provider "bunnynet" {}
