# The one client in this module whose values are not written into Infisical.
#
# Every other client here is consumed by a cluster workload, which reads it through the Infisical
# operator. Forgejo runs on brokkr, outside the cluster, and that node holds no store credential at
# all — its secrets are pushed as 0600 env files by ansible/roles/forge. So the values leave through
# outputs and are filed into Proton Pass by hand, the same way tofu/b2 hands over k8up's Backblaze
# key.
#
# Read them with:
#
#   just tf output oidc -raw forgejo_oidc_client_id
#   just tf output oidc -raw forgejo_oidc_client_secret
#
# then file both into the Proton Pass `brokkr-forgejo` item, as `oidc client id` and
# `oidc client secret`, and re-run `just ans setup brokkr --tags podman`. That rewrites
# /etc/futhark/forgejo.env and re-runs `forgejo admin auth update-oauth`, which is what makes a
# rotation reach the running Forgejo.

output "forgejo_oidc_client_id" {
  description = "File into Proton Pass as brokkr-forgejo/oidc client id."
  # Not secret, but not knowable ahead of the apply either: Pocket ID generates the client ID, and
  # the provider's optional client_id argument only takes effect at create time. Marked sensitive for
  # the same reason the B2 key id is — it is identifying, so it is printed only when asked for by
  # name.
  value     = pocketid_client.forgejo.id
  sensitive = true
}

output "forgejo_oidc_client_secret" {
  description = "File into Proton Pass as brokkr-forgejo/oidc client secret. Read it with `tofu output -raw`."
  value       = pocketid_client.forgejo.client_secret
  sensitive   = true
}
