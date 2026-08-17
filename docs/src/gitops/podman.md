# The standalone Podman plane

How `brokkr` runs and reconciles workloads without Kubernetes, what it holds and what it
deliberately does not, and how to change what runs on it. At the end of
[Changing what runs](#changing-what-runs) a commit has reached the node and restarted the container
it affects.

`brokkr` hosts the forge: Forgejo at `git.$DOMAIN` and Woodpecker CI at `ci.$DOMAIN`, both on the
public internet. It is a Fedora host provisioned by the same Ansible plane as the cluster nodes, on
the same NetBird mesh, and it runs no Kubernetes at all.

That is the whole design constraint. A forge holding a mirror of this repository is what you reach
for **when the cluster is broken**, so nothing on it may depend on the cluster. Pocket ID, Flux,
cert-manager, the Infisical operator and both Traefiks are cluster workloads; `brokkr` uses none of
them. It logs in against Pocket ID for convenience and keeps one local admin account for when that
is unavailable.

```d2
direction: right

classes: {
  boundary: {
    style: {
      stroke-width: 3
      stroke: seagreen
      fill: honeydew
    }
  }
  external: {
    style: {
      stroke: goldenrod
      fill: cornsilk
    }
  }
  muted: {
    style.stroke: dimgray
  }
  denied: {
    style: {
      stroke: firebrick
      stroke-dash: 4
    }
  }
}

github: "GitHub\npublic repository" { class: external }
operator: operator machine {
  ansible: Ansible
}

brokkr: brokkr {
  timer: futhark-quadlet.timer
  units: /etc/containers/systemd
  env: "/etc/futhark/*.env" { class: boundary }
  traefik: Traefik
  forgejo: Forgejo
  woodpecker: Woodpecker

  timer -> units: rsync + envsubst
  units -> traefik
  units -> forgejo
  units -> woodpecker
  env -> forgejo: EnvironmentFile
  env -> woodpecker: EnvironmentFile
}

cluster: k3s cluster {
  pocketid: Pocket ID
}

github -> brokkr.timer: "anonymous clone,\nno credential"
operator.ansible -> brokkr.env: "pushed, 0600"
brokkr.forgejo -> cluster.pocketid: "OIDC login,\nfor everyone but the admin" { class: muted }
cluster -> brokkr: "nothing reconciles,\nnothing is read" { class: denied }
```

Green is the one thing on the node that git never sees. Amber is a third party. The dashed red edge
is the property the whole node exists for: the cluster provides `brokkr` with nothing, so a cluster
outage cannot take the forge with it. The grey edge is the one direction of dependency that does
exist, and it degrades to the local admin account rather than to no access.

## Two halves, and why the split

Config is **pulled** from git. Secrets are **pushed** by Ansible. Nothing crosses.

| Half    | Lives in                                    | Reaches the node via                       | Changing it                           |
| ------- | ------------------------------------------- | ------------------------------------------ | ------------------------------------- |
| Config  | `nodes/brokkr.podman/`                      | `futhark-quadlet.timer`, every 5 minutes   | commit and push                       |
| Secrets | Proton Pass, referenced from `config/sops/` | `ansible/roles/forge`, into 0600 env files | `just ans setup brokkr --tags podman` |

The split is forced. Infisical's free tier caps machine identities at five and three are already
spent, and giving `brokkr` one would also mean the node holding a credential that reads almost the
whole project. Instead it holds no store credential at all, which keeps the tier boundary in
[Secrets](../conventions/secrets.md) intact: the node's secrets are files that Ansible wrote, and
nothing on the node can fetch a secret it was not given.

The cost is real and worth stating: a rotated secret does not reconcile. It reaches the node only
when someone runs Ansible. See [Credential rotation](../operations/rotation.md).

## The reconciler

`ansible/roles/quadlet_gitops` installs a oneshot service and a 5-minute timer.
`/usr/local/bin/futhark-quadlet.sh` does five things:

1. `git fetch` in `/var/lib/futhark-gitops`, then compare `HEAD` to `origin/master`. Unchanged is
   the common case and exits immediately, so a tight interval costs one fetch.
2. `git merge --ff-only`. A rewritten branch fails loudly here rather than merging into whatever the
   node holds.
3. Render every file under `nodes/brokkr.podman/` through `envsubst`, resolving `${DOMAIN}` and
   `${SUB_INTERNAL}` from `/etc/futhark/substitutions.env`.
4. `rsync --delete` the rendered `units/` into `/etc/containers/systemd/` and `config/` into
   `/etc/futhark/`, then `systemctl daemon-reload`.
5. Restart what changed, and publish the applied revision as a node-exporter textfile metric.

The clone is anonymous HTTPS against the public remote. That is deliberate: no deploy key, no
credential on the node, nothing to rotate, and the reconciliation works with Proton Pass and the
cluster both unavailable.

Four properties follow from this and are the ones to hold in mind:

- **`rsync --delete` is what makes it reconciliation rather than a copy.** Delete a unit file in git
  and the unit is gone from the node; `daemon-reload` then stops and reaps its container. There is
  no separate teardown step and no orphan.
- **A bad commit rolls forward, not back.** Nothing keeps a previous revision to return to, so
  recovery is another commit. This is the same contract Flux has.
- **`*.env` is excluded from the config rsync.** Those files are Ansible's, they hold the node's
  secrets, and an unguarded `--delete` would remove them on every run. `substitutions.env` survives
  for the same reason.
- **A config change restarts everything.** Traefik's static configuration is read once at process
  start, and which containers read a given config file is not derivable from its name, so the
  reconciler does not guess. A changed `.container` file restarts only that one service.

### Why envsubst

The domain is an identifying value and this repository is public, so no file here spells it out.
In the cluster, Flux resolves `${DOMAIN}` from the `cluster-values` Secret with
`postBuild.substituteFrom`. Off-cluster there is no Flux, so the reconciler does the same
substitution from a file Ansible writes. The variable names are the same ones on purpose, so a unit
file reads like a manifest. See [Domains](../conventions/domains.md).

Only named variables are substituted, so a literal `$` elsewhere survives. The `$$` escaping a
Flux-reconciled manifest needs does not apply here.

## Quadlet, and the units

Quadlet is a systemd generator. A `*.container` file in `/etc/containers/systemd/` becomes a
`*.service` unit at `daemon-reload` time, so `forgejo.container` yields `forgejo.service`. Until
that reload runs, a new file is not a unit and `systemctl start` cannot find it.

Podman rather than Docker because Fedora ships it, needs no third-party repository, and generates
systemd units natively, which this repository already uses for
[the mesh watchdog](../ansible/mesh-watchdog.md) and
[the egress exporter](../ansible/egress-exporter.md). Rootful rather than rootless, which is the
simpler choice and not the safer one: it binds 443 and 22 with no port-floor sysctl and needs no
lingering user session.

| Unit                          | Serves                       | Holds                                                   |
| ----------------------------- | ---------------------------- | ------------------------------------------------------- |
| `brokkr.network`              | container DNS, subnet pinned | nothing                                                 |
| `traefik.container`           | 443                          | ACME account and certificates in `/srv/futhark/traefik` |
| `forgejo.container`           | 22, and 3000 on the loopback | repositories and SQLite in `/srv/futhark/forgejo`       |
| `woodpecker-server.container` | nothing published            | SQLite in `/srv/futhark/woodpecker-server`              |
| `woodpecker-agent.container`  | nothing published            | the Podman socket                                       |

Non-secret configuration is `Environment=` lines in the unit, so it is reviewable in a diff.
Secrets are `EnvironmentFile=` only. A local username counts as identifying, which is why
`WOODPECKER_ADMIN` is in the env file rather than the unit.

Image pins are `tag@sha256:…`, the same rule as everywhere else in the repository, and Renovate
opens the bumps through a custom manager in `.github/renovate.json5`, since no built-in manager
reads a systemd unit file. See [Dependency updates](../conventions/updates.md).

### TLS without cert-manager

Traefik issues its own certificates over ACME **TLS-ALPN-01**, answered on the 443 listener that
already exists. The two alternatives were both worse here:

- DNS-01, which the cluster uses, needs the Bunny API key. That is a crown-jewel credential, and
  putting it on a node whose secrets are files on disk widens its blast radius for nothing.
- HTTP-01 needs port 80 open, which `roles/podman_host` deliberately does not open, for the same
  reason `roles/firewall_ingress` closes it on the edge node.

The cost is that TLS-ALPN-01 cannot issue a wildcard, so each hostname needs its own record and its
own certificate. With two hostnames that is the cheaper trade. `tofu/bunny` publishes the two `A`
records; nothing writes a challenge record into that zone for these two.

### The Woodpecker agent holds the Podman socket

The agent runs each pipeline step as a container, which means speaking the container runtime's API,
which means holding its socket. On a rootful host that socket is root: a pipeline step can mount any
path on the node.

This is inherent to containerised CI rather than a shortcut taken here, but it should be stated
plainly. **Anyone who can author a pipeline on `brokkr` effectively owns `brokkr`.** What bounds it:

- `WOODPECKER_OPEN=false`, so a Forgejo user cannot enrol themselves into Woodpecker.
- `FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION=true`, so Forgejo accounts come from Pocket ID
  or from the admin, never from a sign-up form.
- `WOODPECKER_AUTHENTICATE_PUBLIC_REPOS=false`, so a public repository's pipelines are not run for
  anonymous events.

Traefik is on the same host and gets no socket at all, which is why it uses the file provider rather
than Podman service discovery.

## Authentication

Two paths, and the second exists because the first depends on the cluster.

**Pocket ID, for everyone.** `tofu/oidc` registers a `pocketid_client` and
`ansible/roles/forge_bootstrap` registers it in Forgejo as an OAuth login source named `pocketid`.
The callback path is `/user/oauth2/pocketid/callback`, where the middle segment is that source name,
so the two have to spell the same word. Forgejo has no app.ini section for a login source, so
`forgejo admin auth add-oauth` is the only handle there is; the role runs `update-oauth` on every
converge after the first, which is what makes a rotated client secret reach the running Forgejo.

**One local admin, for when Pocket ID is down.** A username and password in Proton Pass, created by
the same role. This is the account that makes the node worth having, so verifying it works is not
optional. Woodpecker's own admin is the same username, which is why `WOODPECKER_ADMIN` is set.

Woodpecker authenticates against Forgejo, not against Pocket ID. A Woodpecker user is a Forgejo user
who granted it access, so the chain is browser to Woodpecker to Forgejo to Pocket ID. That OAuth
application is created inside Forgejo and is the one credential here that no plane in this
repository can mint.

## Backups

`brokkr` writes to its own restic repository in its own B2 bucket, provisioned by `tofu/b2` with a
key scoped to that bucket alone. It is deliberately not the cluster's repository: restic has no
per-path access control, so a key that can write there can read every cluster snapshot ever taken.

`futhark-forge-backup.timer` runs nightly at 03:00. The script takes a `sqlite3 .backup` of each
database into `/srv/futhark/backup`, then `restic backup` over the data directories and that
staging directory, tagged `forge`. `futhark-forge-prune.timer` runs `restic check` and then
`restic forget --prune` weekly, in that order: pruning an already-damaged repository writes the
damage in.

Files, not `forgejo dump`. A dump writes a fresh archive every run, which restic cannot deduplicate
against the previous one, so gigabytes of git data would be re-uploaded nightly. The live
repository directory deduplicates almost perfectly. The databases cannot be copied that way,
because a live SQLite file may hold a partial transaction, which is what the `.backup` step is for.

Retention matches the cluster's: 14 daily, 8 weekly, 6 monthly. Restore procedure is in
[Backup and recovery](../operations/recovery.md#brokkr).

## Changing what runs

```bash
$EDITOR nodes/brokkr.podman/units/forgejo.container
git commit -am 'feat(brokkr): ...' && git push
```

Verify, within five minutes:

```bash
ssh brokkr journalctl -u futhark-quadlet -n 20
ssh brokkr systemctl status forgejo.service
```

Expect the reconciler's log to name the new short revision and the service to have restarted. To
apply it immediately instead of waiting:

```bash
ssh brokkr systemctl start futhark-quadlet.service
```

Removing a workload is deleting its `.container` file and pushing. Confirm with
`ssh brokkr podman ps`, which should no longer list it.

## Common failures

**A container is `activating (start)` and then fails, with `Failed to load environment files`.**
The env file `ansible/roles/forge` writes is missing. This is the first-converge ordering: the role
runs before `quadlet_gitops` for exactly this reason, so it means the run did not get that far.

```bash
just ans setup brokkr --tags podman
```

**The reconciler reports success and nothing changed.** The revision matched, so it short-circuited.
Confirm what the node actually holds:

```bash
ssh brokkr git -C /var/lib/futhark-gitops rev-parse --short HEAD
```

**`futhark_quadlet_last_run_success` is 0.** Read the journal. The two failures that are not
transient are an `envsubst` on a file referencing a variable that is not in
`substitutions.env` (which renders empty rather than failing) and a `merge --ff-only` against a
rewritten branch.

**A certificate is not renewing.** Traefik logs the ACME exchange at INFO. TLS-ALPN-01 needs the
challenge to reach this node's 443 directly, so anything terminating TLS in front of it breaks
issuance. Gatus asserts `[CERTIFICATE_EXPIRATION] > 240h` on both hostnames, which is the alert
that fires first.
