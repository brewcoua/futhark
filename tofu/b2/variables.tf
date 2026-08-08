# Declared in this module's refs.env and read from infra/substitutions/app/backup-location.sops.yaml
# at plan/apply time — that file is the canonical record, because Velero's BackupStorageLocation is
# a CR whose bucket is fixed when the manifest renders, so Flux has to have it. Not held in this
# module's secrets.sops.env: a second encrypted copy of the same name drifts silently, and it
# would also *win*, since `sops exec-env` runs after the refs are exported.
variable "backups_bucket" {
  description = "Name of the B2 bucket Velero writes to — same value Flux substitutes into $${B2_BUCKET}."
  type        = string
  validation {
    condition     = length(var.backups_bucket) > 0
    error_message = "backups_bucket must not be empty."
  }
}

# Also from backup-location.sops.yaml. A B2 bucket has no region argument — the region is a fact
# of the account, fixed when it was created — so nothing here sets it. It is declared because the
# S3 endpoint derives from it, for this module's own backend and for Velero's s3Url alike, and
# account.tf asserts the account agrees.
variable "region" {
  description = "B2 region, e.g. eu-central-003. Not a bucket setting — the S3 endpoint derives from it."
  type        = string
  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-\\d{3}$", var.region))
    error_message = "region must look like a B2 region, e.g. eu-central-003."
  }
}
