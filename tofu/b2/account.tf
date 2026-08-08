data "b2_account_info" "this" {}

# A wrong B2_REGION is the failure this catches. Nothing rejects it: Flux renders
# https://s3.<wrong>.backblazeb2.com into Velero's s3Url quite happily, and the symptom is an
# opaque 400 and a BackupStorageLocation stuck Unavailable — with the daily Schedule still green
# until the 26h alert in infra/monitoring fires. The account knows the right endpoint, so ask it.
#
# A check block, not a variable validation: this compares a committed value against the provider's
# view of the account, which validation cannot reach. It warns rather than fails, and that is the
# right shape — a mismatch here does not make the plan for the bucket wrong.
check "region_matches_account" {
  assert {
    condition     = data.b2_account_info.this.s3_api_url == "https://s3.${var.region}.backblazeb2.com"
    error_message = "B2_REGION in infra/substitutions/app/backup-location.sops.yaml says ${var.region}, but this account's S3 endpoint is ${data.b2_account_info.this.s3_api_url}. Velero's s3Url derives from that value, so fix the Secret."
  }
}
