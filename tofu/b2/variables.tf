# Declared in this module's refs.env and read from config/sops/cluster.sops.yaml at plan/apply time —
# that file is the canonical record, because Flux substitutes the bucket into K8up's operator
# environment when the HelmRelease renders, so Flux has to have it. Not held in this module's own
# `tofu.b2` section: a second encrypted copy of the same name drifts silently, and it would also
# *win*, since a module's own values are exported after the refs.
variable "backups_bucket" {
  description = "Name of the B2 bucket K8up's restic repository lives in — same value Flux substitutes into $${B2_BUCKET}."
  type        = string
  validation {
    condition     = length(var.backups_bucket) > 0
    error_message = "backups_bucket must not be empty."
  }
}

# The passphrase OpenTofu derives this module's state encryption key from, out of this module's own
# `tofu.b2` section. Resolved at `tofu init`, not just plan/apply: an encryption block has to settle
# before the backend is read, so every recipe in .just/tofu.just that touches the backend needs it.
variable "state_passphrase" {
  description = "Passphrase for state encryption. From Proton Pass via config/sops/ops.sops.yaml."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters — the pbkdf2 key provider's minimum."
  }
}

# Also from config/sops/cluster.sops.yaml. A B2 bucket has no region argument — the region is a fact
# of the account, fixed when it was created — so nothing here sets it. It is declared because the
# S3 endpoint derives from it, for this module's own backend and for restic's repository URL alike,
# and account.tf asserts the account agrees.
variable "region" {
  description = "B2 region, e.g. eu-central-003. Not a bucket setting — the S3 endpoint derives from it."
  type        = string
  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-\\d{3}$", var.region))
    error_message = "region must look like a B2 region, e.g. eu-central-003."
  }
}
