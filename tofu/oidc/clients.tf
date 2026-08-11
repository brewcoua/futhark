# The domain is SOPS-encrypted, so it comes in as a Tofu variable — extracted from
# config/sops/cluster.sops.yaml via refs.env. See docs/src/conventions/domains.md.

# One pocketid_client + infisical_secret pair per app — add a block per app as it adopts OIDC
# login. Each app owns its purely static OIDC config (discovery URL, hostname) in its own
# ConfigMap; this module produces the two values that can't be: the client secret, and the
# client ID, which Pocket ID mints itself.

# actual — nodes/kenaz.k8s/actual. Confidential client: Actual sends its own client secret to
# Pocket ID's token endpoint server-side, never exposed to the browser.
resource "pocketid_client" "actual" {
  name          = "Actual Budget"
  callback_urls = ["https://actual.${var.sub_internal}.${var.domain}/openid/callback"]
  is_public     = false
  pkce_enabled  = true
}

# /nodes/kenaz/actual in the prod environment — the path
# nodes/kenaz.k8s/actual/app/infisicalsecret.yaml reads as its InfisicalStaticSecret source, and
# the only path the tofu-writer identity may write. That sync is folder-wide, so both keys below
# land in the actual-secrets Secret the Deployment already pulls in via envFrom.
resource "infisical_secret" "actual_openid_client_secret" {
  name         = "ACTUAL_OPENID_CLIENT_SECRET"
  value        = pocketid_client.actual.client_secret
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/actual"
}

# Not secret, but not knowable ahead of the apply either: Pocket ID generates the client ID and
# the provider's optional `client_id` argument only takes effect at create time, so an existing
# client keeps its generated UUID. Shipping it through Infisical rather than the ConfigMap means
# the value follows whatever the client actually is, including after a replacement.
resource "infisical_secret" "actual_openid_client_id" {
  name         = "ACTUAL_OPENID_CLIENT_ID"
  value        = pocketid_client.actual.id
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/actual"
}
