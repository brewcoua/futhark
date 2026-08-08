terraform {
  required_version = ">= 1.7.0"
  required_providers {
    netbird = {
      source = "netbirdio/netbird"
      # Exact, not "~> 0.0.9". A 2-component "~> 0.0" would allow any 0.x release — Terraform's
      # ~> only fixes the components to the left of the last one given — which is not what a 0.x
      # provider's own semver convention promises: minor bumps there are breaking. And a 0.0.x
      # provider promises nothing even between patch releases, so the only honest pin is the
      # exact version. Renovate proposes the bump; the plan is read before it lands.
      version = "0.0.9"
    }
  }
}

# token comes from NB_PAT — pass-cli run resolves the `pass://` reference in
# secrets.sops.env before tofu ever sees it. management_url is left at its default
# (https://api.netbird.io), which is NetBird Cloud; self-hosting later means setting it here
# and in ansible/roles/netbird, and nothing else. See docs/src/tofu/netbird.md.
provider "netbird" {}
