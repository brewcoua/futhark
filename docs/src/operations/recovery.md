# Backup and recovery

Git holds every declaration and Infisical holds every runtime secret, so
[Cold bootstrap](setup.md) rebuilds the cluster from both. What neither covers is PVC data. That
is what Velero is for, and it is the only part of this cluster that cannot be reconstructed by
re-running something.

Use this page to decide whether a volume is protected, to restore one namespace, or to rebuild a
node or the whole cluster.

## Prerequisites

- `kubectl` access. Every `just bak`, `just ks` and `just fx` recipe sets `KUBECONFIG` itself.
- For a full rebuild: the GPG smartcard, a Proton Pass session, and Proton Pass still holding the
  Kopia repository password and the SSE-C key. Without those two the bucket is noise.

## What is backed up, and what is not

Four tiers, decided by where a volume already lives rather than by how important it is.

| Data                  | Where it lives                          | Durability                      |
| --------------------- | --------------------------------------- | ------------------------------- |
| SQLite and app state  | `local-path`, node-local hostPath       | Velero to Backblaze B2, nightly |
| Attachments and blobs | `storagebox-crypt`, offsite over rclone | The Storage Box's own snapshots |
| Bulk media            | `gdrive-crypt`, offsite over rclone     | **None.** See below             |
| Everything else       | git and Infisical                       | Reconciled back by Flux         |

A `local-path` volume is on one node's disk. Lose that disk and the data is gone, which is why
that tier is the one Velero carries. `storagebox-crypt` is already offsite and already
snapshotted. Copying it to B2 would be a second offsite copy of the same bytes, paid for twice.

`gdrive-crypt` is excluded for a different reason, and the distinction matters because the two
classes look alike from the cluster. Google Drive has trash and per-file version history. It has
nothing that restores a directory tree to a point in time. A deletion that propagates through
rclone is gone once trash expires, and `drive-use-trash=false` on that class means it does not
even reach trash. So the class is for data you can re-fetch or afford to lose. Put anything
irreplaceable on it and you must opt the pod into Velero explicitly, with the annotation below,
which then pulls every byte back through rclone and up to B2. That is usually the sign it belonged
on a different class.

Nothing infers this. A volume is backed up only if its **pod** carries an annotation naming it:

```yaml
template:
  metadata:
    annotations:
      backup.velero.io/backup-volumes: server-files
```

The schedule sets `defaultVolumesToFsBackup: false`, so the annotation is the only switch. That is
why `nodes/kenaz.k0s/actual` names `server-files` and not `user-files`. The omission is the
tiering. Adding an app with a `local-path` PVC means adding this annotation, and nothing else in
`infra/backup/` needs editing.

Currently annotated: Actual's budget SQLite, Pocket ID's users and passkeys, Grafana's
`grafana.db`. VictoriaMetrics and VictoriaLogs deliberately are not. Both expire their own data
within weeks, and metrics are not worth the egress.

Resource manifests are collected cluster-wide, because they are cheap and make a backup
self-describing. **Secrets are excluded.** Nothing is lost by it: Infisical is the source of truth
for every runtime secret and git owns the rest, so no Secret in a backup would ever be the only
copy.

Verify what a given backup actually copied, rather than that it ran:

```bash
just bak describe <backup>
```

A backup that copied nothing still reports `Completed`.

## Encryption

Velero's defaults are weaker than they look, and two of the files in `infra/backup/app/` exist
only to fix that.

| What reaches B2                       | Protected by                                         | Key held in                 |
| ------------------------------------- | ---------------------------------------------------- | --------------------------- |
| Volume data, in a Kopia repository    | AES-256-GCM, client-side                             | `KOPIA_REPOSITORY_PASSWORD` |
| Resource manifests, a gzipped tarball | SSE-C, so Backblaze stores ciphertext it cannot read | `B2_SSE_C_KEY`              |

Left alone, Velero encrypts the Kopia repository with a password **hardcoded in its own source**,
published and identical in every installation. `secret-repo.yaml` is what replaces it, and it has
to exist before the node-agent first initialises the repository. The password is baked in at
creation and cannot be changed afterwards without starting a new repo.

The manifest tarballs get no client-side encryption from Velero at all, which is what
`customerKeyEncryptionFile` on the `BackupStorageLocation` closes. Both keys come from Infisical
under `/infra/velero`, and both belong in Proton Pass.

**Losing either key loses every backup, irrecoverably.** There is no recovery path, by design.
That is the same property that keeps Backblaze from reading them.

Both keys, and the B2 application key, are read with a machine identity of their own rather than
the `cluster-reader` every other namespace uses. See
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced).

Of the three, only the B2 application key can be replaced. [`b2`](../tofu/b2.md) is what mints it,
along with the bucket, its lifecycle rules and the reason there is no object lock on it. The
rotation procedure is
[Credential rotation](rotation.md#veleros-b2-key), and the same page states plainly which
credentials cannot be rotated at all.

## Restore a namespace

**This deletes data.** The recipe removes the namespace's `local-path` PVCs and recreates them
from a backup. It prints what it will destroy and what it will leave alone, then makes you type
the namespace back before it proceeds.

Look at what you have first:

```bash
just bak backups                  # every backup and its status
just bak describe <backup>        # which volumes it actually copied, with sizes
```

Then restore:

```bash
just bak restore actual
```

Pass `-- actual/daily-20260729030014` to pick a specific backup. The default is the newest
completed one.

Verify: the namespace's pods return to `Running` with their data present, and
`just fx failing` is empty once Flux resumes.

What the recipe does that a hand-run `velero restore create` does not:

- Suspends the Flux Kustomization that owns the namespace first. Flux recreates a deleted PVC
  within its reconcile interval, which races the restore and wins often enough to matter.
- Scales the namespace's workloads to zero. A PVC with a running pod on it stays `Terminating`
  forever.
- Runs `flux resume` at the end, which is what puts the replica counts back.

If the recipe fails part way through, the namespace can be left suspended and scaled to zero.
Resume it by hand:

```bash
just fx reconcile <kustomization>
```

## Rebuild a wiped node

A corrupted host gets reinstalled, which destroys every `local-path` volume on it. Both nodes hold
some: Pocket ID is pinned to `ogma`, Actual to `kenaz`, and the monitoring stack floats.

1. Reinstall the OS, then:

   ```bash
   just ans setup <host>
   ```

   The `netbird` role registers the node again and writes the new mesh IP back into
   `ansible/nodes/<host>/host.sops.yml`. Commit that change.

2. Delete the node's old peer from the NetBird dashboard. The rejoin creates a new one, and the
   stale peer otherwise sits in the groups holding an address nothing answers on.
3. Rejoin the cluster, reinstall the local-path provisioner, and re-seed the Flux and Infisical
   credentials:

   ```bash
   just ans k0s
   ```

4. Wait for Flux. `just fx failing` must come back empty. The apps return with empty PVCs.
5. Restore each namespace that had data on that node:

   ```bash
   just bak restore <namespace>
   ```

Step 5 is per namespace on purpose. There is no restore-everything task, because a restore is a
destructive operation and the set of namespaces that actually lost data is a judgement the
operator makes, not one a script should guess.

## Rebuild the whole cluster

[Cold bootstrap](setup.md) gets you a running, empty cluster. Velero comes back with it, since the
`BackupStorageLocation` is in git and the credentials are in Infisical, and it re-syncs the bucket
on its own. Existing backups reappear in `just bak backups` within a minute or so of the pod
starting. Then restore per namespace as above.

What you need out of band is unchanged from the cold bootstrap: the GPG smartcard that opens SOPS,
and a Proton Pass session. The backup-specific addition is that Proton Pass must still hold the
Kopia repository password and the SSE-C key.

## Where the pieces are

| Piece                                      | Path                                                |
| ------------------------------------------ | --------------------------------------------------- |
| Velero release, credentials, repo password | `infra/backup/app/`                                 |
| The nightly `Schedule`                     | `infra/backup/config/schedule.yaml`                 |
| Which bucket, which region                 | `infra/substitutions/app/backup-location.sops.yaml` |
| The bucket itself, and Velero's B2 key     | `tofu/b2`, see [b2](../tofu/b2.md)                  |
| The B2 keys and both encryption keys       | Infisical, `/infra/velero`                          |
| Restore and inspection tasks               | `.just/velero.just`                                 |
| Failure alerts                             | `infra/monitoring/app/grafana/alerting/backup.yaml` |

The alerts are what makes the rest trustworthy. One fires on a failed or partially failed backup.
One fires when no backup has succeeded in 26 hours, which is the only rule that catches a
suspended schedule or an expired B2 key, where nothing fails because nothing ran.

## Failure modes

**Every backup completes and copies nothing.** Velero's node-agent reads pod volumes from the
kubelet's root directory, and its chart default points at `/var/lib/kubelet`. k0s puts it at
`/var/lib/k0s/kubelet`, the same override `infra/storage` needs for `kubeletDir`. Left at the
default, the path exists but holds no pods, so the backup succeeds having copied nothing. The
symptom is `just bak describe <backup>` listing zero volumes.

**`BackupStorageLocation` stuck `Unavailable` while the `Schedule` reads green.** The B2
credentials in `/infra/velero` are wrong or expired. Nothing fails loudly, because the schedule
does not test the location.

**A restore hangs with a PVC `Terminating`.** A pod still has it mounted. `just bak restore`
scales workloads to zero for this reason; if you ran `velero restore create` by hand, scale them
down yourself.
