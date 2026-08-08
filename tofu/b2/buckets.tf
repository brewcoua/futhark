# Velero's target. Not the bucket holding this module's own state — that one is created by hand at
# bootstrap and stays unmanaged, because a module cannot create the bucket its state lives in.
#
# bucket_name forces replacement, and replacing this bucket means losing every backup in it. It is
# read from the file Flux reads, so the two cannot disagree; changing it is a deliberate migration,
# not a rename.
resource "b2_bucket" "backups" {
  bucket_name = var.backups_bucket
  bucket_type = "allPrivate"

  # No file_lock_configuration: Kopia rewrites and deletes its own objects during maintenance, and
  # object lock would fail those writes rather than protect anything.
  #
  # No rule that touches current versions either. Retention belongs to Velero's Schedule
  # (ttl 720h, infra/backup/config/schedule.yaml) and Kopia's own maintenance; a B2-side deletion
  # of live objects would corrupt the repository, and the corruption would surface at restore
  # time, which is the worst possible moment to find it. These two rules only reap what Kopia has
  # already finished with.
  lifecycle_rules {
    file_name_prefix = ""
    # Interrupted multipart uploads are invisible in the bucket listing and billed anyway.
    days_from_starting_to_canceling_unfinished_large_files = 1
    # Once Kopia hides an object, B2 keeps the old version forever unless told otherwise. 30 days
    # rather than 1: it bounds the cost of version sprawl while still leaving a month's window to
    # undo an accidental — or malicious — repository wipe.
    days_from_hiding_to_deleting = 30
  }
}
