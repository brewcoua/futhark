data "b2_account_info" "this" {}

# A wrong B2_REGION is the failure this catches. Nothing rejects it: Flux renders
# https://s3.<wrong>.backblazeb2.com into BACKUP_GLOBALS3ENDPOINT quite happily, and the symptom is
# every backup job failing to reach a host that does not resolve. The account knows the right
# endpoint, so ask it.
#
# A check block, not a variable validation: this compares a committed value against the provider's
# view of the account, which validation cannot reach. It warns rather than fails, and that is the
# right shape — a mismatch here does not make the plan for the bucket wrong.
check "region_matches_account" {
  assert {
    condition     = data.b2_account_info.this.s3_api_url == "https://s3.${var.region}.backblazeb2.com"
    error_message = "B2_REGION in config/sops/cluster.sops.yaml says ${var.region}, but this account's S3 endpoint is ${data.b2_account_info.this.s3_api_url}. K8up's restic endpoint derives from that value, so fix the Secret."
  }
}
