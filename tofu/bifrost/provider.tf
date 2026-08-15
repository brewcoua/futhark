terraform {
  required_version = ">= 1.7.0"
  required_providers {
    infisical = {
      source  = "Infisical/infisical"
      version = "~> 0.19"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Same settings and the same `tofu-writer` machine identity as tofu/oidc, for the same reasons.
# See tofu/oidc/provider.tf.
provider "infisical" {
  host = "https://eu.infisical.com"
  auth = {
    universal = {}
  }
}
