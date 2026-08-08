terraform {
  required_version = ">= 1.7.0"
  required_providers {
    b2 = {
      source = "Backblaze/b2"
      # Patch-level only — see tofu/netbird/provider.tf for why a 2-component "~>" is
      # looser than it looks on a 0.x provider.
      version = "~> 0.13.2"
    }
  }
}

# application_key_id/application_key come from B2_APPLICATION_KEY_ID/B2_APPLICATION_KEY —
# pass-cli run resolves them before tofu ever sees them. Deliberately not the account's master
# key: an application key can hold writeBuckets/writeKeys, and the master key is the one
# credential B2 will not accept on the S3 API, which this module's own backend speaks. See
# docs/src/tofu/b2.md.
provider "b2" {}
