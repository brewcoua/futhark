# Backup and recovery

Git holds every declaration, Infisical holds every runtime secret, and
[Cold bootstrap](setup.md) rebuilds the cluster from both. What neither covers is PVC data.
That is what Velero is for, and it is the only part of this cluster that cannot be
reconstructed by re-running something.

## What is backed up, and what is not

Three tiers, decided by where a volume already lives rather than by how important it is.

| Data                  | Where it lives                          | Durability                      |
| --------------------- | --------------------------------------- | ------------------------------- |
| SQLite and app state  | `local-path`, node-local hostPath       | Velero → Backblaze B2, nightly  |
| Attachments and blobs | `storagebox-crypt`, offsite over rclone | The Storage Box's own snapshots |
| Everything else       | git and Infisical                       | Reconciled back by Flux         |

A `local-path` volume is on one node's disk. Lose that disk and the data is gone, which is why
that tier is the one Velero carries. `storagebox-crypt` is already offsite and already
snapshotted; copying it to B2 would be a second offsite copy of the same bytes, paid for twice.

Nothing infers this. A volume is backed up only if its **pod** carries an annotation naming it:

```yaml
template:
  metadata:
    annotations:
      backup.velero.io/backup-volumes: server-files
```

The schedule sets `defaultVolumesToFsBackup: false`, so the annotation is the only switch. That
is why `nodes/kenaz.k0s/actual` names `server-files` and not `user-files` — the omission is the
tiering. Adding an app with a `local-path` PVC means adding this annotation; nothing else in
`infra/backup/` needs editing.

Currently annotated: Actual's budget SQLite, Pocket ID's users and passkeys, Grafana's `grafana.db`.
VictoriaMetrics and VictoriaLogs deliberately are not — both expire their own data within weeks,
and metrics are not worth the egress.

Resource manifests are collected cluster-wide, because they are cheap and make a backup
self-describing. **Secrets are excluded.** Nothing is lost by it: Infisical is the source of
truth for every runtime secret and git owns the rest, so no Secret in a backup would ever be the
only copy.

## Encryption

Velero's defaults are weaker than they look, and two of the files in `infra/backup/app/` exist
only to fix that.

| What reaches B2                       | Protected by                                       | Key held in                 |
| ------------------------------------- | -------------------------------------------------- | --------------------------- |
| Volume data, in a Kopia repository    | AES-256-GCM, client-side                           | `KOPIA_REPOSITORY_PASSWORD` |
| Resource manifests, a gzipped tarball | SSE-C — Backblaze stores ciphertext it cannot read | `B2_SSE_C_KEY`              |

Left alone, Velero encrypts the Kopia repository with a password **hardcoded in its own source**
— published, and identical in every installation. `secret-repo.yaml` is what replaces it, and it
has to exist before the node-agent first initialises the repository: the password is baked in at
creation and cannot be changed afterwards without starting a new repo.

The manifest tarballs get no client-side encryption from Velero at all, which is what
`customerKeyEncryptionFile` on the `BackupStorageLocation` closes. Both keys come from Infisical
under `/infra/velero`, and both belong in Proton Pass.

**Losing either key loses every backup, irrecoverably.** There is no recovery path, by design —
that is the same property that keeps Backblaze from reading them.

Both keys, and the B2 application key, are read with a machine identity of their own rather than
the cluster-reader every other namespace uses. See
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced).

## Restore a namespace

```bash
task bak:restore -- actual
```

This **deletes** the namespace's `local-path` PVCs and recreates them from a backup, so it prints
what it will destroy and what it will leave alone, then makes you type the namespace back before
it proceeds. Pass `-- actual/daily-20260729030014` to pick a specific backup; the default is the
newest completed one.

What it does that a hand-run `velero restore create` does not: suspend the Flux Kustomization
that owns the namespace first. Flux recreates a deleted PVC within its reconcile interval, which
races the restore and wins often enough to matter. The task also scales the namespace's
workloads to zero — a PVC with a running pod on it stays `Terminating` forever — and `flux resume`
at the end is what puts the replica counts back.

Before that, look at what you have:

```bash
task bak:backups                  # every backup and its status
task bak:describe -- <backup>     # which volumes it actually copied, with sizes
```

`bak:describe` is the one to check after any change to the node-agent: a backup that copied
nothing still reports `Completed`.

## Rebuild a wiped node

A corrupted host gets reinstalled, which destroys every `local-path` volume on it. Both nodes
hold some: Pocket ID is pinned to `ogma`, Actual to `kenaz`, and the monitoring stack floats.

1. Reinstall the OS, then `task ans:setup -- <host>`. The `tailscale` role registers the node
   again and writes the new mesh IP back into `ansible/nodes/<host>/host.sops.yml`.
2. `task ans:k0s` — rejoins the node, reinstalls the local-path provisioner, re-seeds the Flux
   and Infisical credentials.
3. Wait for Flux: `task fx:failing` should come back empty. The apps return with empty PVCs.
4. `task bak:restore -- <ns>` for each namespace that had data on that node.

Step 4 is per namespace on purpose. There is no restore-everything task, because a restore is a
destructive operation and the set of namespaces that actually lost data is a judgement the
operator makes, not one a script should guess.

## Rebuild the whole cluster

[Cold bootstrap](setup.md) gets you a running, empty cluster. Velero comes back with it — the
`BackupStorageLocation` is in git, the credentials are in Infisical — and re-syncs the bucket on
its own, so existing backups reappear in `task bak:backups` within a minute or so of the pod
starting. Then restore per namespace as above.

What you need out of band is unchanged from the cold bootstrap: the GPG smartcard that opens
SOPS, and a Proton Pass session. The backup-specific addition is that Proton Pass must still hold
the Kopia repository password and the SSE-C key, since without them the bucket is noise.

## Where the pieces are

| Piece                                      | Path                                                |
| ------------------------------------------ | --------------------------------------------------- |
| Velero release, credentials, repo password | `infra/backup/app/`                                 |
| The nightly `Schedule`                     | `infra/backup/config/schedule.yaml`                 |
| Which bucket, which region                 | `infra/substitutions/app/backup-location.sops.yaml` |
| The B2 keys and both encryption keys       | Infisical, `/infra/velero`                          |
| Restore and inspection tasks               | `.taskfiles/velero/Taskfile.yaml`                   |
| Failure alerts                             | `infra/monitoring/app/grafana/alerting/backup.yaml` |

The alerts are the part that makes the rest trustworthy: one fires on a failed or partially
failed backup, and one fires when no backup has succeeded in 26 hours — which is the only rule
that catches a suspended schedule or an expired B2 key, where nothing fails because nothing ran.

## k0s and the node-agent

Velero's node-agent reads pod volumes from the kubelet's root directory, and its chart default
points at `/var/lib/kubelet`. k0s puts it at `/var/lib/k0s/kubelet` — the same override
`infra/storage` needs for `kubeletDir`.

The failure mode is silent, which is the reason it is worth knowing. Left at the default, the
path exists but holds no pods, so every backup completes successfully having copied nothing. The
symptom is `task bak:describe -- <backup>` listing zero volumes.
