# Velero's credential, scoped to the one bucket. The module mints it and stops there: the outputs
# below are filed into Infisical /infra/velero by hand, per the rule in docs/src/tofu/index.md.
# tofu/oidc is the one module that writes to a secret store, and it stays the only one.
#
# capabilities and bucket_ids both force replacement, so editing either mints a new key and leaves
# the old one live in the account until it is revoked — which is also how rotation works. See
# docs/src/tofu/b2.md.
#
# No readBucketEncryption: the backups are SSE-C, which is a per-request header Velero sends from
# its own key file, not a bucket setting anyone needs to read.
resource "b2_application_key" "velero" {
  key_name     = "velero"
  bucket_ids   = [b2_bucket.backups.bucket_id]
  capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles", "deleteFiles"]
}

# B2_KEY_ID and B2_APPLICATION_KEY in Infisical /infra/velero, which infra/backup/app/secret.yaml
# templates into Velero's credentials file. The id is not sensitive on its own, but it is
# identifying, so it is printed only when asked for by name.
output "velero_b2_key_id" {
  description = "File into Infisical /infra/velero as B2_KEY_ID."
  value       = b2_application_key.velero.application_key_id
  sensitive   = true
}

output "velero_b2_application_key" {
  description = "File into Infisical /infra/velero as B2_APPLICATION_KEY. Shown once per mint; read it with `tofu output -raw`."
  value       = b2_application_key.velero.application_key
  sensitive   = true
}
