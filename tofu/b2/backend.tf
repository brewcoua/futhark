# The one module whose state is remote, against the rule in docs/src/tofu/index.md. The reason is
# specific to B2: `b2_bucket`'s importer takes a bucket_id and nothing else, and bucket names are
# globally unique, so a second operator machine starting from empty state does not adopt the
# existing bucket — it fails the apply with duplicate_bucket_name. Remote state is what makes the
# module portable at all.
#
# What normally forbids that is a minted credential sitting in state in plaintext, which
# b2_application_key.velero is. The state object is written under SSE-C
# (AWS_SSE_CUSTOMER_KEY, from Proton Pass), so Backblaze stores ciphertext it holds no key for —
# the same property infra/backup relies on for the backups themselves. Lose that key and you lose
# the state, not the backups: recoverable by re-import.
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
