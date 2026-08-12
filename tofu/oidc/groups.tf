# Fleet-wide groups. Every client in clients.tf admits these two and nothing else, and an app that
# maps roles reads the same `groups` claim — Grafana turns administrators into Admin and users
# into Viewer. `name` is what lands in the claim; `friendly_name` only shows in Pocket ID's UI.
#
# Membership is not managed here: a Pocket ID user is created by enrolling a passkey, so the
# account exists before Tofu could reference it. Assign people in the admin UI.
#
# `allowed_user_groups` starts rejecting everyone outside these groups the moment a client picks
# it up, so on the first apply create the groups, add yourself in the UI, then apply the rest:
#
#   just tf apply oidc -target=pocketid_group.administrators -target=pocketid_group.users
#   just tf apply oidc
resource "pocketid_group" "administrators" {
  name          = "administrators"
  friendly_name = "Administrators"
}

resource "pocketid_group" "users" {
  name          = "users"
  friendly_name = "Users"
}
