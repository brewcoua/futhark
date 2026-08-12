# Backup and recovery

Git holds every declaration and Infisical holds every runtime secret, so
[Cold bootstrap](setup.md) rebuilds the cluster from both. What neither covers is PVC data. That
is what K8up is for, and it is the only part of this cluster that cannot be reconstructed by
re-running something.

Use this page to decide whether a volume is protected, to restore one namespace, or to rebuild a
node or the whole cluster.

## Prerequisites

- `kubectl` access. Every `just bak`, `just ks` and `just fx` recipe sets `KUBECONFIG` itself.
- For a full rebuild: the GPG smartcard, a Proton Pass session, and Proton Pass still holding the
  restic repository password. Without it the bucket is noise.

## What is backed up, and what is not

Four tiers, decided by where a volume already lives rather than by how important it is.

| Data                  | Where it lives                          | Durability                      |
| --------------------- | --------------------------------------- | ------------------------------- |
| SQLite and app state  | `local-path`, node-local hostPath       | K8up to Backblaze B2, nightly   |
| Attachments and blobs | `storagebox-crypt`, offsite over rclone | The Storage Box's own snapshots |
| Bulk media            | `gdrive-crypt`, offsite over rclone     | **None.** See below             |
| Everything else       | git and Infisical                       | Reconciled back by Flux         |

A `local-path` volume is on one node's disk. Lose that disk and the data is gone, which is why
that tier is the one K8up carries. `storagebox-crypt` is already offsite and already snapshotted.
Copying it to B2 would be a second offsite copy of the same bytes, paid for twice.

`gdrive-crypt` is excluded for a different reason, and the distinction matters because the two
classes look alike from the cluster. Google Drive has trash and per-file version history. It has
nothing that restores a directory tree to a point in time. A deletion that propagates through
rclone is gone once trash expires, and `drive-use-trash=false` on that class means it does not
even reach trash. So the class is for data you can re-fetch or afford to lose. Put anything
irreplaceable on it and you must opt the PVC in explicitly, with the annotation below, which then
pulls every byte back through rclone and up to B2. That is usually the sign it belonged on a
different class.

## Deciding what gets copied

Two independent switches, and a volume needs both.

**A `Schedule` puts the namespace in scope.** They all live in
`infra/backup/config/schedules.yaml`, one per namespace, sharing every field except the namespace
itself — the cron expression and the job history limits are patched in by
`infra/backup/config/kustomization.yaml`. A namespace with no `Schedule` is never visited.

They are central rather than in each app's own directory because a `Schedule` needs the `k8up.io`
CRDs, so an app shipping its own would need `dependsOn: backup` on its Kustomization — which
would stop Pocket ID reconciling whenever the backup stack was unhealthy.

**A PVC annotation opts the volume in.** The operator runs with
`skipWithoutAnnotation: true`, so nothing is inferred:

```yaml
metadata:
  annotations:
    k8up.io/backup: "true"
```

That annotation lives next to the PVC it names, because what to keep is a property of the app.
It is why `nodes/kenaz.k8s/actual` annotates `actual-server-files` and not `actual-user-files`.
The omission is the tiering. VictoriaMetrics and VictoriaLogs sit unannotated in a namespace that
does have a `Schedule`: both already expire their own data, and metrics are not worth the egress.

Currently annotated: Actual's budget SQLite, Pocket ID's users and passkeys, Grafana's
`grafana.db`.

### Excluding paths inside a volume

A volume is rarely all state. Grafana's is 257 MB, of which `grafana.db` is 1.3 MB and the rest is
a plugins directory Grafana reinstalls on its own. Pocket ID's is 68 MB, 62 MB of it MaxMind's
GeoLite2 database, downloaded and refreshed by the app.

restic arguments pass through a second annotation on the same PVC:

```yaml
k8up.io/backup-restic-args: '["--exclude=/data/grafana/plugins"]'
```

K8up mounts each PVC at `/data/<claim-name>`, which is where those paths come from. The value is
a JSON array. A malformed one does not fail the backup — K8up logs `failed to parse restic backup
args from the annotation` and **skips that PVC entirely**, so check the snapshot after changing
it.

Between them the two excludes take the nightly copy from about 340 MB to about 7 MB.

### What is not backed up at all

Kubernetes resource manifests. Velero collected them cluster-wide; K8up backs up volume data and
nothing else. Nothing is lost by it: git owns every declaration and Infisical owns every runtime
secret, so no manifest in a backup would ever be the only copy.

### SQLite is copied live

The nightly job copies `pocket-id.db` and Actual's budget databases as files, alongside whatever
`-wal` and `-shm` sit next to them. That is a crash-consistent copy, not a quiesced one: restoring
it is equivalent to recovering from a power cut, which SQLite handles, but it is not the same as a
dump. `k8up.io/backupcommand` would take a real `sqlite3 .backup` instead, and needs `sqlite3` to
exist in each image. Not adopted yet.

## Encryption

restic encrypts the repository client-side with AES-256 before anything leaves the cluster, so
Backblaze stores ciphertext it cannot read. One password does it, `RESTIC_PASSWORD` in Infisical
`/infra/k8up`, handed to the operator as `BACKUP_GLOBALREPOPASSWORD`.

The password is baked into the repository at creation and cannot be changed afterwards without
starting a new one. **Losing it loses every backup, irrecoverably.** There is no recovery path, by
design — that is the same property that keeps Backblaze from reading them. It belongs in Proton
Pass, and it must be there before the first backup runs.

It, and the B2 application key, are read with a machine identity of their own rather than the
`cluster-reader` every other namespace uses. See
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced).

Of the two, only the B2 application key can be replaced. [`b2`](../tofu/b2.md) is what mints it,
along with the bucket, its lifecycle rules and the reason there is no object lock on it. The
rotation procedure is [Credential rotation](rotation.md#the-backup-b2-key), and the same page
states plainly which credentials cannot be rotated at all.

## Repository maintenance

`infra/backup/config/schedule-maintenance.yaml` runs weekly in the `k8up` namespace, and is the
only place check and prune run. There is one restic repository behind every `Schedule`, so a prune
from `auth` would forget snapshots belonging to `monitoring` just the same; running it once also
avoids three jobs contending for restic's exclusive prune lock.

- `check` reads every pack file and verifies it against the index. This is the only thing that
  catches bit rot or a truncated upload, and it catches it while there is still an older snapshot
  to fall back on rather than at restore time.
- `prune` applies the retention policy: 14 daily, 8 weekly, 6 monthly.

A prune reclaims no billed storage for a further 30 days, because the bucket's
`days_from_hiding_to_deleting` rule keeps hidden versions that long.

## Inspect what actually happened

```bash
just bak schedules          # every Schedule and its most recent jobs
just bak snapshots          # every restic snapshot, and which volume it holds
just bak jobs               # backup, check and prune jobs, newest last
just bak logs <job> <ns>    # restic's summary of what that run copied
```

Snapshot objects carry no size, so a run that copied nothing looks identical to one that worked.
The job log is where the file and byte counts are, which makes `just bak logs` the check that
matters after any change to an annotation.

Back up a namespace immediately instead of waiting for 03:00:

```bash
just bak now monitoring
```

## Restore a namespace

**This deletes data.** The recipe removes the namespace's `local-path` PVCs, recreates them empty
and restores the newest snapshot of each. It prints what it will destroy and what it will leave
alone, then makes you type the namespace back before it proceeds.

Look at what you have first:

```bash
just bak snapshots
```

Then restore:

```bash
just bak restore actual
```

Verify: the namespace's pods return to `Running` with their data present, and
`just fx failing` is empty once Flux resumes.

What the recipe does that a hand-written `Restore` does not:

- Suspends the Flux Kustomization that owns the namespace first. Flux recreates a deleted PVC
  within its reconcile interval, which races the restore and wins often enough to matter. Any
  HelmRelease targeting the namespace is suspended too — a chart-created PVC, like Grafana's,
  appears in no Kustomization inventory at all.
- Scales the namespace's workloads to zero. A PVC with a running pod on it stays `Terminating`
  forever.
- Recreates each PVC from its own live spec rather than letting Flux do it. K8up restores into an
  existing claim, and resuming Flux to get one back would also scale the workloads up again,
  straight onto a volume that is still empty.
- Sets `spec.paths` on each `Restore`. A restic snapshot holds exactly one path, so there is no
  snapshot that carries a whole namespace; without that field a restore of one volume can land
  another volume's contents.
- Runs `flux resume` at the end, which is what puts the replica counts back.

If the recipe fails part way through, the namespace can be left suspended and scaled to zero.
Resume it by hand:

```bash
just fx reconcile <kustomization>
```

## Restore by hand, with restic

Worth knowing because it does not depend on the cluster being up. Take `B2_KEY_ID`,
`B2_APPLICATION_KEY` and `RESTIC_PASSWORD` from Infisical `/infra/k8up` (or Proton Pass, for the
last one), then:

```bash
export RESTIC_REPOSITORY="s3:https://s3.<region>.backblazeb2.com/<bucket>"
export RESTIC_PASSWORD=...
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

restic snapshots
restic restore <id> --target /restore
```

`<region>` and `<bucket>` are `B2_REGION` and `B2_BUCKET` in `config/sops/cluster.sops.yaml`.

## Rebuild a wiped node

A corrupted host gets reinstalled, which destroys every `local-path` volume on it. Both nodes hold
some: Pocket ID is pinned to `ogma`, Actual to `kenaz`, and the monitoring stack floats.

1. Reinstall the OS, then:

   ```bash
   just ans setup <host>
   ```

   The `netbird` role registers the node again and writes the new mesh IP back into
   `nodes.<host>.mesh_ip` in `config/sops/ops.sops.yaml`. Commit that change. If the node is the edge
   one, update `MESH_IP` in `config/sops/cluster.sops.yaml` to match.

2. Delete the node's old peer from the NetBird dashboard. The rejoin creates a new one, and the
   stale peer otherwise sits in the groups holding an address nothing answers on.
3. Rejoin the cluster, reinstall the local-path provisioner, and re-seed the Flux and Infisical
   credentials:

   ```bash
   just ans k8s
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

[Cold bootstrap](setup.md) gets you a running, empty cluster. K8up comes back with it, since the
`Schedule` resources are in git and the credentials are in Infisical. Snapshots reappear in
`just bak snapshots` once the operator has synced them from the repository. Then restore per
namespace as above.

What you need out of band is unchanged from the cold bootstrap: the GPG smartcard that opens SOPS,
and a Proton Pass session. The backup-specific addition is that Proton Pass must still hold the
restic repository password.

## Where the pieces are

| Piece                                 | Path                                                |
| ------------------------------------- | --------------------------------------------------- |
| K8up release and credentials          | `infra/backup/app/`                                 |
| Which namespaces are in scope         | `infra/backup/config/schedules.yaml`                |
| Check, prune and the retention policy | `infra/backup/config/schedule-maintenance.yaml`     |
| Which volumes, and what to exclude    | The `k8up.io/*` annotations on each PVC             |
| Which bucket, which region            | `config/sops/cluster.sops.yaml`                     |
| The bucket itself, and the B2 key     | `tofu/b2`, see [b2](../tofu/b2.md)                  |
| The B2 key and the restic password    | Infisical, `/infra/k8up`                            |
| Restore and inspection tasks          | `.just/backup.just`                                 |
| Failure alerts                        | `infra/monitoring/app/grafana/alerting/backup.yaml` |

The alerts are what makes the rest trustworthy. One fires on any failed K8up job, backup, check or
prune alike. One fires when a namespace has had no successful backup in 26 hours, which is the
only rule that catches a deleted `Schedule` or an expired B2 key, where nothing fails because
nothing ran.

## Failure modes

**A volume silently stops being backed up.** A typo in `k8up.io/backup-restic-args` makes K8up
skip the PVC and carry on, and the remaining volumes still produce a successful job. The symptom
is a missing entry in `just bak snapshots`; the cause is in the job log, as `failed to parse
restic backup args from the annotation`.

**Every job fails immediately.** The B2 credentials in `/infra/k8up` are wrong or expired, or
`B2_REGION` does not match the account. `tofu/b2`'s check block catches the second at plan time.

**A restore hangs with a PVC `Terminating`.** A pod still has it mounted. `just bak restore`
scales workloads to zero for this reason; if you wrote the `Restore` by hand, scale them down
yourself.

**Storage keeps growing after a prune.** Expected for 30 days. The bucket keeps hidden object
versions that long, deliberately, so an accidental or malicious repository wipe stays undoable.
