# Same source of truth as config/domain/domain.env, read straight from that file
# so nothing drifts — see tofu/bunny/dns.tf for the same pattern.
locals {
  domain_env_file = file("${path.module}/../../config/domain/domain.env")
  int_domain      = regex("(?m)^INT_DOMAIN=(.*)$", local.domain_env_file)[0]
}

# One pocketid_client + infisical_secret pair per app — add a block per app as it adopts OIDC
# login. Each app owns its own non-secret OIDC config (client ID, discovery URL, hostname) in
# its own ConfigMap; this module only produces the one thing that can't be committed: the
# client secret.

# actual — nodes/kenaz.k0s/actual. Confidential client: Actual sends its own client secret to
# Pocket ID's token endpoint server-side, never exposed to the browser.
resource "pocketid_client" "actual" {
  name          = "Actual Budget"
  callback_urls = ["https://actual.${local.int_domain}/openid/callback"]
  is_public     = false
  pkce_enabled  = true
}

# /nodes/kenaz/actual in the prod environment — the path
# nodes/kenaz.k0s/actual/app/externalsecret.yaml reads as its InfisicalStaticSecret source, and
# the only path the tofu-writer identity may write. Only the client secret goes here; every
# non-secret value already lives in that app's ConfigMap.
resource "infisical_secret" "actual_openid_client_secret" {
  name         = "ACTUAL_OPENID_CLIENT_SECRET"
  value        = pocketid_client.actual.client_secret
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/actual"
}
