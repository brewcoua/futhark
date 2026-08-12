# The one module whose state is remote, against the rule in docs/src/tofu/index.md. The reason is
# specific to B2: `b2_bucket`'s importer takes a bucket_id and nothing else, and bucket names are
# globally unique, so a second operator machine starting from empty state does not adopt the
# existing bucket — it fails the apply with duplicate_bucket_name. Remote state is what makes the
# module portable at all.
#
# What normally forbids that is a minted credential sitting in state in plaintext, which
# b2_application_key.k8up is. The encryption block below is what makes it safe: OpenTofu
# encrypts the state client-side, so what B2 receives is already ciphertext. Lose the passphrase
# and you lose the state, not the backups: recoverable by re-import.
#
# This was SSE-C (AWS_SSE_CUSTOMER_KEY) until 2026-08-10 and silently did nothing — OpenTofu
# validates that variable's length and then writes the object without the customer-key headers, so
# the state sat readable in the bucket with the backup B2 key in it. Client-side encryption is checkable
# by eye, which is the actual reason to prefer it: fetch the object and it is not JSON.
#
# A *partial* configuration. bucket, key, region and endpoint arrive as -backend-config from
# .just/tofu.just, because a literal bucket name here would be an identifying value committed in
# the clear, which this repo does not do anywhere else.
terraform {
  backend "s3" {
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    # B2 rejects the AWS SDK's trailing checksum — the same incompatibility
    # infra/backup/app/helmrelease.yaml works around with checksumAlgorithm: "".
    skip_s3_checksum = true
    # Off because B2's S3 API does not honour the If-None-Match conditional write the lockfile is
    # built on (hashicorp/terraform#37143): with it on, no apply ever acquires the lock. Safe
    # only while there is exactly one operator running exactly one apply at a time.
    use_lockfile = false
  }
}

# Client-side, so it holds whatever the backend is and whatever B2 does or does not honour. The
# passphrase arrives as TF_VAR_state_passphrase — a variable rather than the `passphrase` literal,
# because a literal here would be a committed credential, and rather than TF_ENCRYPTION, because
# `pass-cli run` only rewrites a variable whose whole value is a pass:// URI and TF_ENCRYPTION
# would have to hold a block of HCL wrapped around one.
#
# No fallback: an unencrypted one was here for the migration off SSE-C, and it is gone because
# while it is present a plaintext state object is still accepted. Rotating the passphrase means
# adding a fallback again, keyed to the old one — see docs/src/operations/rotation.md.
terraform {
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method = method.aes_gcm.state
    }
    # Not because a plan file is written today, but because `-out` would put the same credential
    # in one.
    plan {
      method = method.aes_gcm.state
    }
  }
}
