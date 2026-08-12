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
  # Actual has no role model to map onto, so both groups get the same access.
  allowed_user_groups = [
    pocketid_group.administrators.id,
    pocketid_group.users.id,
  ]
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

# grafana — infra/monitoring. The callback path is not a choice: Grafana always uses
# <root_url>/login/<provider>, and the provider here is generic_oauth.
resource "pocketid_client" "grafana" {
  name          = "Grafana"
  callback_urls = ["https://dash.${var.sub_internal}.${var.domain}/login/generic_oauth"]
  is_public     = false
  pkce_enabled  = true
  # Grafana maps these to Admin and Viewer in its own role_attribute_path, so the two have to
  # name the same groups.
  allowed_user_groups = [
    pocketid_group.administrators.id,
    pocketid_group.users.id,
  ]
}

# /infra/monitoring is the folder infra/monitoring/app/grafana/secret.yaml already syncs into the
# `grafana` Secret, which the chart loads whole with envFromSecret. It is a second path the
# tofu-writer identity has to be allowed to write — see docs/src/tofu/oidc.md.
resource "infisical_secret" "grafana_oidc_client_secret" {
  name         = "GRAFANA_OIDC_CLIENT_SECRET"
  value        = pocketid_client.grafana.client_secret
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/infra/monitoring"
}

resource "infisical_secret" "grafana_oidc_client_id" {
  name         = "GRAFANA_OIDC_CLIENT_ID"
  value        = pocketid_client.grafana.id
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/infra/monitoring"
}
