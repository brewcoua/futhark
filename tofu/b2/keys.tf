# K8up's credential, scoped to the one bucket. The module mints it and stops there: the outputs
# below are filed into Infisical /infra/k8up by hand, per the rule in docs/src/tofu/index.md.
# tofu/oidc is the one module that writes to a secret store, and it stays the only one.
#
# capabilities and bucket_ids both force replacement, and replacement is destroy-then-create: the
# old key is deleted before the new one exists, so editing either — or rotating with -replace —
# breaks backups until the new values reach Infisical, with no way back. See
# docs/src/operations/rotation.md.
#
# deleteFiles is not optional here even though a backup never deletes: restic's prune is what
# reclaims space, and it does so by deleting pack files.
#
# No readBucketEncryption: restic encrypts client-side, so nothing about the bucket's own
# encryption settings is ever read.
resource "b2_application_key" "k8up" {
  key_name     = "k8up"
  bucket_ids   = [b2_bucket.backups.bucket_id]
  capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles", "deleteFiles"]
}

# B2_KEY_ID and B2_APPLICATION_KEY in Infisical /infra/k8up, which infra/backup/app/secret.yaml
# hands to the operator as BACKUP_GLOBALACCESSKEYID and BACKUP_GLOBALSECRETACCESSKEY. The id is
# not sensitive on its own, but it is identifying, so it is printed only when asked for by name.
output "k8up_b2_key_id" {
  description = "File into Infisical /infra/k8up as B2_KEY_ID."
  value       = b2_application_key.k8up.application_key_id
  sensitive   = true
}

output "k8up_b2_application_key" {
  description = "File into Infisical /infra/k8up as B2_APPLICATION_KEY. Shown once per mint; read it with `tofu output -raw`."
  value       = b2_application_key.k8up.application_key
  sensitive   = true
}
