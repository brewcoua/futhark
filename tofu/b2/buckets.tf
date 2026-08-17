# The restic repository K8up writes to. Not the bucket holding this module's own state — that one
# is created by hand at bootstrap and stays unmanaged, because a module cannot create the bucket
# its state lives in.
#
# bucket_name forces replacement, and replacing this bucket means losing every backup in it. It is
# read from the file Flux reads, so the two cannot disagree; changing it is a deliberate migration,
# not a rename.
resource "b2_bucket" "backups" {
  bucket_name = var.backups_bucket
  bucket_type = "allPrivate"

  # No file_lock_configuration: restic rewrites and deletes its own pack files during prune, and
  # object lock would fail those writes rather than protect anything.
  #
  # No rule that touches current versions either. Retention belongs to the prune schedule and its
  # keep policy (config/k8up); a B2-side deletion of live objects would corrupt the repository, and
  # the corruption would surface at restore time, which is the worst possible moment to find it.
  # These two rules only reap what restic has already finished with.
  lifecycle_rules {
    file_name_prefix = ""
    # Interrupted multipart uploads are invisible in the bucket listing and billed anyway.
    days_from_starting_to_canceling_unfinished_large_files = 1
    # Once restic hides an object, B2 keeps the old version forever unless told otherwise. 30 days
    # rather than 1: it bounds the cost of version sprawl while still leaving a month's window to
    # undo an accidental — or malicious — repository wipe. It also means a prune reclaims nothing
    # for 30 days.
    days_from_hiding_to_deleting = 30
  }
}

# brokkr's restic repository. A second bucket rather than a prefix in the one above, because a restic
# repository has no per-path access control: a key that can write brokkr's snapshots into the
# cluster's repository can also read every snapshot already in it. That is the blast radius
# docs/src/conventions/secrets.md isolates behind a separate Infisical identity for the cluster, and
# a bucket boundary is the same isolation done with the tool that actually enforces it.
#
# Same replacement warning as above: bucket_name forces replacement, and replacing this bucket means
# losing every snapshot of the forge.
resource "b2_bucket" "brokkr" {
  bucket_name = var.brokkr_bucket
  bucket_type = "allPrivate"

  # Identical to the cluster repository's, and for identical reasons. Retention here belongs to
  # futhark-forge-prune.service on the node, not to B2.
  lifecycle_rules {
    file_name_prefix                                       = ""
    days_from_starting_to_canceling_unfinished_large_files = 1
    days_from_hiding_to_deleting                           = 30
  }
}
