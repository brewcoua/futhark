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

# brokkr's credential, scoped to its own bucket and nothing else. The scoping is the point: this node
# is outside the cluster, holds its secrets as files on disk rather than behind an operator, and must
# not be able to read the cluster's backups if it is compromised.
#
# Same replacement semantics as k8up's, so the same warning applies: editing capabilities or
# bucket_ids destroys the key before creating its replacement, and brokkr's backups fail until the new
# values reach Proton Pass and `just ans setup brokkr --tags podman` rewrites /etc/futhark/restic.env.
resource "b2_application_key" "brokkr" {
  key_name     = "brokkr"
  bucket_ids   = [b2_bucket.brokkr.bucket_id]
  capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles", "deleteFiles"]
}

# Filed into Proton Pass rather than Infisical, unlike k8up's pair above: brokkr runs no Infisical
# operator and holds no store credential, so Ansible is what puts these on the node. They go into the
# `brokkr-restic` item, which config/sops/ops.sops.yaml references as
# ansible.secrets.brokkr.B2_KEY_ID and .B2_APPLICATION_KEY.
output "brokkr_b2_key_id" {
  description = "File into Proton Pass as brokkr-restic/key id."
  value       = b2_application_key.brokkr.application_key_id
  sensitive   = true
}

output "brokkr_b2_application_key" {
  description = "File into Proton Pass as brokkr-restic/application key. Shown once per mint; read it with `tofu output -raw`."
  value       = b2_application_key.brokkr.application_key
  sensitive   = true
}
