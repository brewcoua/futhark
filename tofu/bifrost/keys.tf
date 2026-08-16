# The virtual keys Bifrost issues its clients, and the only reason this module exists.
#
# Nothing here talks to Bifrost. A virtual key's token is whatever
# nodes/kenaz.k8s/bifrost/app/configmap.yaml declares it to be, through an `env.` reference, so
# minting one is generating a string and filing it where each side reads it. What the key is
# allowed to reach stays in that ConfigMap, in git, next to the providers it names.
#
# The alternative was the third-party AirHelp-OSP/bifrost provider, which creates virtual keys over
# Bifrost's management API. That moves the scope out of git into the config store, and makes an
# apply depend on Bifrost already running and reachable at a mesh-only host.
#
# The `sk-bf-` prefix is not cosmetic: a virtual key without it is accepted on the `x-bf-vk` header
# only, and every client here sends `Authorization` or `x-api-key` instead.

# open-webui's key. Read twice: once by Bifrost, to know the token, and once by Open WebUI, to
# send it. One decision, so one resource and two writes rather than two values kept in step by
# hand.
resource "random_password" "vk_open_webui" {
  length = 48
  # The token travels in HTTP headers and in a JSON config file. Alphanumeric keeps it clear of
  # both, and 48 characters leaves the entropy far above what the shorter charset costs.
  special = false
}

# The key for CLI clients on the mesh: Claude Code, Gemini CLI, anything else pointed at
# llm.$SUB_INTERNAL.$DOMAIN by hand. Separate from open-webui's so either can be revoked alone,
# which is done by rotating one of these two resources rather than editing the ConfigMap.
resource "random_password" "vk_cli" {
  length  = 48
  special = false
}

# Vane's key. Read twice like open-webui's: once by Bifrost and once by the app. Its own key
# rather than a shared one, because the point of a virtual key here is that one app can be revoked
# without touching the others.
#
# Its entry in nodes/kenaz.k8s/bifrost/app/config.json names the ollama provider only. The app has
# no use for cli-proxy, and a key that cannot reach it cannot spend the subscription quota behind
# it on a runaway search loop.
resource "random_password" "vk_vane" {
  length  = 48
  special = false
}

# Kvasir's key. Scoped to the ollama provider only, for the same reason as Vane's and more sharply:
# a STORM run is an unattended loop that spends minutes issuing model calls, so a key that cannot
# reach cli-proxy cannot drain the subscription quota behind it when a run goes wrong.
resource "random_password" "vk_kvasir" {
  length  = 48
  special = false
}

# /nodes/kenaz/bifrost in the prod environment, the path
# nodes/kenaz.k8s/bifrost/app/infisicalsecret.yaml reads. That folder also holds four hand-seeded
# keys: BIFROST_ENCRYPTION_KEY, BIFROST_ADMIN_USERNAME, BIFROST_ADMIN_PASSWORD and OLLAMA_API_KEY.
# The sync is folder-wide, so all eight land in the bifrost-secrets Secret the Deployment pulls in
# via envFrom.
resource "infisical_secret" "vk_open_webui" {
  name         = "VK_OPEN_WEBUI"
  value        = "sk-bf-${random_password.vk_open_webui.result}"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/bifrost"
}

resource "infisical_secret" "vk_cli" {
  name         = "VK_CLI"
  value        = "sk-bf-${random_password.vk_cli.result}"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/bifrost"
}

resource "infisical_secret" "vk_vane" {
  name         = "VK_VANE"
  value        = "sk-bf-${random_password.vk_vane.result}"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/bifrost"
}

resource "infisical_secret" "vk_kvasir" {
  name         = "VK_KVASIR"
  value        = "sk-bf-${random_password.vk_kvasir.result}"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/bifrost"
}

# The same token again, under the name Open WebUI expects, in the folder Open WebUI reads. This
# second write is the whole point of putting the key in tofu: the value has to be identical on both
# sides, and a value typed into two Infisical folders drifts the first time one is rotated.
resource "infisical_secret" "open_webui_bifrost_key" {
  name         = "OPENAI_API_KEYS"
  value        = infisical_secret.vk_open_webui.value
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/open-webui"
}

# The same token again, under the name Vane reads it by. It calls the field OPENAI_API_KEY because
# it configures Bifrost through its generic OpenAI provider. That name is not ours to choose.
resource "infisical_secret" "vane_bifrost_key" {
  name         = "OPENAI_API_KEY"
  value        = infisical_secret.vk_vane.value
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/vane"
}

# The same token again, under the name Kvasir reads it by. OPENAI_API_KEY is not a name either side
# chose: litellm and knowledge_storm's Encoder read it out of the environment directly, and an alias
# is how embedding calls end up at api.openai.com instead of at bifrost.
resource "infisical_secret" "kvasir_bifrost_key" {
  name         = "OPENAI_API_KEY"
  value        = infisical_secret.vk_kvasir.value
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/nodes/kenaz/kvasir"
}

# VK_CLI has no cluster consumer: it is typed into a shell on the operator's machine. Read it with
# `just tf output bifrost -raw vk_cli`, which is also how a rotation hands over the new value.
output "vk_cli" {
  description = "Virtual key for CLI clients on the mesh."
  value       = infisical_secret.vk_cli.value
  sensitive   = true
}
