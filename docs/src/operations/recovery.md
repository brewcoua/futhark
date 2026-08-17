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

Five tiers, decided by where the data already lives rather than by how important it is.

| Data                  | Where it lives                          | Durability                      |
| --------------------- | --------------------------------------- | ------------------------------- |
| SQLite and app state  | `local-path`, node-local hostPath       | K8up to Backblaze B2, nightly   |
| PostgreSQL rows       | `local-path`, in the `postgres` cluster | `pg_dumpall` to the same bucket |
| Attachments and blobs | `storagebox-crypt`, offsite over rclone | The Storage Box's own snapshots |
| Bulk media            | `gdrive-crypt`, offsite over rclone     | **None.** See below             |
| Everything else       | git and Infisical                       | Reconciled back by Flux         |
| The forge's state     | `brokkr`, outside the cluster           | restic to its own B2 bucket     |

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

The last row is the one this page's machinery does not cover at all. `brokkr` is not in the cluster,
so K8up does not see it and no `Schedule` names it; it runs its own restic timer against its own
bucket. Everything below is about the cluster's repository, and brokkr's is in
[brokkr](#brokkr).

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
The omission is the tiering. VictoriaMetrics and VictoriaLogs already expire their own data, and
metrics are not worth the egress, so neither is annotated. That left the `monitoring` namespace
with nothing annotated at all once Grafana's state moved to PostgreSQL, which is why it no longer
has a `Schedule` either.

Currently annotated: Actual's budget SQLite, Linkwarden's page archives, Open WebUI's uploads and
vector store, Pocket ID's uploaded images, Vane's settings and history. Open WebUI's and Pocket
ID's are the remainder after a migration: the databases behind them moved to PostgreSQL and what
stays on the volume is files.

### A third switch, for PostgreSQL

The shared PostgreSQL is the one workload whose data volume is deliberately left unannotated.
restic copying a running data directory produces a snapshot that looks fine and fails at restore
time, so what gets backed up there is a dump taken at backup time instead:

```yaml
inheritedMetadata:
  annotations:
    k8up.io/backupcommand: /bin/sh -c "pg_dumpall --clean --if-exists -U postgres"
    k8up.io/backupcommand-container: postgres
    k8up.io/file-extension: .sql
```

K8up execs that command inside the running pod and streams its stdout into restic as a single
`.sql` object. Nothing is written to disk first, so the dump is never stale, and every tenant
database is in it. `inheritedMetadata` is how a CloudNativePG `Cluster` puts annotations on its
pods, since it has no pod template of its own.

The recovery point is the last nightly run. Point-in-time recovery would mean continuous WAL
archiving through CloudNativePG's own barman-cloud plugin, which is a second backup system with
its own bucket and retention. Not adopted.

### Excluding paths inside a volume

A volume is rarely all state. Pocket ID's is 68 MB, 62 MB of it MaxMind's GeoLite2 database,
which the app downloads and refreshes on its own.

restic arguments pass through a second annotation on the same PVC:

```yaml
k8up.io/backup-restic-args: '["--exclude=/data/pocketid-data/GeoLite2-City.mmdb"]'
```

K8up mounts each PVC at `/data/<claim-name>`, which is where those paths come from. The value is
a JSON array. A malformed one does not fail the backup — K8up logs `failed to parse restic backup
args from the annotation` and **skips that PVC entirely**, so check the snapshot after changing
it.

The other way to shrink a volume is to stop keeping state on it. Grafana's was 257 MB, of which
`grafana.db` was 1.3 MB and the rest a plugins directory the chart reinstalls; moving that 1.3 MB
into PostgreSQL removed the volume from the backup set entirely rather than excluding most of it.

### What is not backed up at all

Kubernetes resource manifests. Velero collected them cluster-wide; K8up backs up volume data and
nothing else. Nothing is lost by it: git owns every declaration and Infisical owns every runtime
secret, so no manifest in a backup would ever be the only copy.

### SQLite is copied live

The nightly job copies `pocket-id.db` and Actual's budget databases as files, alongside whatever
`-wal` and `-shm` sit next to them. That is a crash-consistent copy, not a quiesced one: restoring
it is equivalent to recovering from a power cut, which SQLite handles, but it is not the same as a
dump. `k8up.io/backupcommand` would take a real `sqlite3 .backup` instead, and needs `sqlite3` to
exist in each image. Not adopted for these, though it is what the `postgres` namespace uses.

`brokkr` does take the quiesced copy, because it is not going through K8up at all and can run
`sqlite3 .backup` on the host against the container's file. Its databases are Forgejo's and
Woodpecker's, and both hold every user's credential, so a crash-consistent copy was not worth the
saving there. See [brokkr](#brokkr).

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
just bak snapshots          # every restic snapshot, the volume it holds and its size
just bak ls <id> [<depth>]  # look inside one, without restoring it
just bak jobs               # backup, check and prune jobs, newest last
just bak logs <job> <ns>    # restic's summary of what that run copied
```

The Snapshot object carries no size, so `just bak snapshots` reads one off restic itself and
joins it on the id. A `0` there is a snapshot that holds nothing, which is what a run that copied
nothing looks like, and is the check that matters after any change to an annotation. It comes
from the summary restic wrote at backup time, so a snapshot taken by a restic older than 0.17
has an empty size rather than a wrong one.

`just bak ls` lists a snapshot's contents with the size of each entry, `eza -T -L<depth>` style.
The depth counts from the volume the snapshot holds rather than from `/`, and defaults to 2:

```bash
just bak ls <id>       # the volume's contents and one level under them
just bak ls <id> 4     # deeper
```

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

## Restore the PostgreSQL dump

**Partly verified.** `just bak pg-dump` has been run against a real snapshot and produces the
`.sql` file. The replay half of `just bak pg-restore` has not yet completed a drill: the first
attempt stopped before reaching `psql`, on a wait that could never finish. Run it once and correct
this section from what actually happens, before relying on it in an incident.

`just bak restore postgres` is the wrong tool here and will not help: it restores `local-path`
PVCs, and this namespace's data is a `.sql` object rather than a volume snapshot.

A `Restore` CR is not an option here, and this is the one place K8up's two halves are not
symmetric. Its own documentation: "You can't restore from backups that were done from `stdin`
(`PreBackupPod` or backup command annotation). In those cases, use the manual restore option
described below using the `restic dump` or `restic mount` commands." So the dump comes back
through restic, which is why `restic` is pinned in `mise.toml`.

Write it to a local file. This touches no database and no cluster state, so it is safe at any
time, and it is also how the drill is done:

```bash
just bak pg-dump                        # newest .sql snapshot
just bak pg-dump <id>                   # a specific one, from just bak snapshots
just bak pg-dump <id> ./somewhere.sql   # somewhere other than .tmp/
```

The B2 key, the restic password, the bucket and the endpoint are read back off the cluster rather
than out of Infisical by hand, so there is one procedure rather than two. Read the head of the
file to see the roles and databases it would recreate.

**Then the destructive half.** `pg_dumpall --clean` drops and recreates every database and role in
the dump, so anything written since the snapshot is gone:

```bash
just bak pg-restore
just bak pg-restore <id>
```

It fetches through `pg-dump` to a file rather than a pipe, so what was applied is still on disk
afterwards. It prints what it will replace and makes you type the namespace back first, then
suspends the tenants' Flux Kustomizations, scales them to zero, replays into the primary over its
local socket, and resumes Flux. Which namespaces count as tenants is read from the `postgres`
policy overlay: whatever is allowed to reach port 5432, minus the operator.

The scale-down is per namespace, not per workload, because nothing declares which pods hold a
database connection. `monitoring` is a tenant, so a replay also stops VictoriaMetrics and
VictoriaLogs for its duration. Expect a gap in metrics and logs across the restore, including the
metrics you would use to judge how it went. DaemonSets are left running throughout; they are
never scaled by this and hold no connection.

Resuming Flux is a shell trap rather than the last line, so an abort anywhere after the
suspension still puts the tenants back. If the process is killed hard enough to skip the trap,
`SIGKILL` or a closed terminal, the cluster is left suspended and at zero replicas. Recover with:

```bash
just fx get                                  # SUSPENDED column shows what is still held
flux resume kustomization <name> [<name>…]
```

Flux restores every replica count from git, so nothing needs scaling back by hand.

Verify: each tenant shows its own data rather than an empty install, and `just fx failing` is
empty.

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

## brokkr

`brokkr` is outside the cluster and backs itself up, so nothing above applies to it. It writes to its
own restic repository in its own B2 bucket, with a key that cannot read the cluster's. That
separation is the whole reason there are two repositories rather than one with two prefixes: restic
has no per-path access control, so a key that can write into a repository can read every snapshot in
it. See [The standalone Podman plane](../gitops/podman.md#backups).

Its credentials are already on the node, in `/etc/futhark/restic.env`, which is the fastest path
when the node itself is what you are recovering:

```bash
ssh brokkr
sudo -i
set -a; . /etc/futhark/restic.env; set +a

restic snapshots --tag forge
```

Off the node, take `RESTIC_PASSWORD`, `B2_KEY_ID` and `B2_APPLICATION_KEY` from the Proton Pass
`brokkr-restic` item, the bucket from `brokkr.B2_BUCKET` in `config/sops/ops.sops.yaml` and the region
from `B2_REGION` in `config/sops/cluster.sops.yaml`, then export them as above.

Each snapshot holds the three data directories and the SQLite staging directory together, so one
snapshot is the whole node's state. To restore it:

```bash
# Restore beside the live data first and read it, rather than over the top of it.
restic restore latest --target /restore

systemctl stop forgejo woodpecker-server woodpecker-agent
cp -a /restore/srv/futhark/forgejo/. /srv/futhark/forgejo/
cp -a /restore/srv/futhark/woodpecker-server/. /srv/futhark/woodpecker-server/
# The live .db files are the ones the containers wrote; the consistent copies are in backup/.
cp /restore/srv/futhark/backup/forgejo.db /srv/futhark/forgejo/forgejo.db
cp /restore/srv/futhark/backup/woodpecker.db /srv/futhark/woodpecker-server/woodpecker.sqlite
systemctl start forgejo woodpecker-server woodpecker-agent
```

The database copies from `backup/` are what to use, not the ones inside the data directories. Those
were captured live and may hold a partial transaction; the ones in `backup/` came from
`sqlite3 .backup` and are consistent.

`/srv/futhark/traefik` is in the snapshot too but is not worth restoring. It holds the ACME account
key and the issued certificates, and Traefik re-issues both on start.

Rehearse this before relying on it. Restoring to `/restore` and confirming
`git -C /restore/srv/futhark/forgejo/git/repositories/<owner>/<repo>.git log` reads and
`sqlite3 /restore/srv/futhark/backup/forgejo.db .tables` opens is the whole rehearsal, and it touches
nothing live.

### Rebuild brokkr from scratch

1. Reinstall the OS, then `just ans setup brokkr`. That converges the runtime, pushes the secrets,
   clones the repository and starts every container from the units in git. The forge comes up empty.
2. Commit the new `nodes.brokkr.mesh_ip` the `netbird` role wrote, and delete the stale peer from the
   NetBird dashboard, exactly as for a cluster node.
3. Restore as above. The bootstrap tasks in `ansible/roles/forge_bootstrap` recreate the local admin
   and the Pocket ID login source against the empty instance, and restoring over them replaces both
   with what the snapshot holds, which is the intended outcome.

Nothing here needs the cluster, Flux or Infisical at any point. That is the property being tested.

## Rebuild a wiped node

A corrupted host gets reinstalled, which destroys every `local-path` volume on it. Both cluster nodes
hold some: Pocket ID is pinned to `ogma`, Actual to `kenaz`, and the monitoring stack floats. For
`brokkr`, which has no `local-path` volume and no cluster to rejoin, the procedure is
[Rebuild brokkr from scratch](#rebuild-brokkr-from-scratch) instead.

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

| Piece                                 | Path                                                                                    |
| ------------------------------------- | --------------------------------------------------------------------------------------- |
| K8up release and credentials          | `infra/backup/app/`                                                                     |
| Which namespaces are in scope         | `infra/backup/config/schedules.yaml`                                                    |
| Check, prune and the retention policy | `infra/backup/config/schedule-maintenance.yaml`                                         |
| Which volumes, and what to exclude    | The `k8up.io/*` annotations on each PVC                                                 |
| Which bucket, which region            | `config/sops/cluster.sops.yaml`                                                         |
| The bucket itself, and the B2 key     | `tofu/b2`, see [b2](../tofu/b2.md)                                                      |
| The B2 key and the restic password    | Infisical, `/infra/k8up`                                                                |
| brokkr's bucket and B2 key            | `tofu/b2`, `brokkr.B2_BUCKET` in `config/sops/ops.sops.yaml`                            |
| brokkr's restic password and B2 key   | Proton Pass, `brokkr-restic`                                                            |
| brokkr's timers and retention         | `ansible/roles/forge`                                                                   |
| Restore and inspection tasks          | `.just/backup.just`                                                                     |
| The PostgreSQL instance and tenants   | `infra/postgres/`, see [Cluster infrastructure](../gitops/infra.md#the-shared-database) |
| Failure alerts                        | `infra/monitoring/app/grafana/alerting/backup.yaml`                                     |

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
