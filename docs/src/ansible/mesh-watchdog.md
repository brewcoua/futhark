# The mesh watchdog

What repairs a node's mesh client when nothing outside the node can reach it, how far the repair
ladder goes, and where it stops. Read this when a healthchecks.io check goes red, or before
tuning any `netbird_watchdog_*` default.

A mesh node is reached over the mesh. `ansible_host` in
`ansible/inventory/group_vars/all/main.yml` resolves to `<hostname>.<mesh_dns_domain>` for any
node with `node.mesh`, and `k0s_cluster` pins kubelet's `--node-ip` and `spec.api.address` to the
mesh address. So a NetBird client that breaks takes down the cluster's view of the node _and_
Ansible's route to it, in the same instant. There is no plane left to fix it from.

That is what the watchdog is for. Every part of it runs on the node, decides locally, and needs
nothing from outside, including the reporting.

`ansible/roles/netbird` installs it on every node the role runs on. Nothing is per-node: a future
node opts in by setting `node.mesh: true`, exactly as it does for the join itself.

## What runs

| Unit                                | What it is                                                         |
| ----------------------------------- | ------------------------------------------------------------------ |
| `netbird.service.d/10-restart.conf` | Drop-in: `Restart=always`, `StartLimitIntervalSec=0`               |
| `futhark-mesh-watchdog.timer`       | Fires the probe every `netbird_watchdog_interval`, 3min after boot |
| `futhark-mesh-watchdog.service`     | Oneshot wrapping `/usr/local/bin/futhark-mesh-watchdog.sh`         |
| `futhark-mesh-routes.service`       | The pod-to-mesh rules, see [Pod to mesh networking](networking.md) |

The drop-in is not part of the ladder and does the most common repair on its own. Plain process
death is systemd's job. What needed overriding is the start limit, which by default gives up
after repeated fast crashes and leaves `netbird.service` permanently `failed`, on a node whose
only route back in is the mesh that daemon carries.

## The probe

One `netbird status --json`, read with `jq`:

- `.management.connected` and `.signal.connected`, the control plane.
- `.netbirdIp` non-empty, meaning the interface is actually addressed.
- Peers whose `.lastWireguardHandshake` falls inside `netbird_watchdog_handshake_max_age`, the
  dataplane. A peer can report `Connected` with a long-dead tunnel, so freshness is read off the
  handshake rather than off the status field. NetBird emits that timestamp as RFC3339 with
  nanosecond precision and a numeric UTC offset, so it is parsed with `date -d`. jq's
  `fromdateiso8601` accepts only whole-second `Z` timestamps and throws on it, which once counted
  every peer stale and put the whole fleet in `degraded` at the same time.

That yields one of three states. A node with no peers at all is `ok`, not `degraded`, because
there is nothing for it to hold a tunnel to.

| State      | `futhark_mesh_state` | Meaning                                           |
| ---------- | -------------------- | ------------------------------------------------- |
| `ok`       | 0                    | Control plane up, at least one fresh handshake    |
| `degraded` | 1                    | Control plane up, every peer's handshake is stale |
| `down`     | 2                    | Daemon dead, or management/signal unreachable     |
| `stuck`    | 3                    | The ladder is exhausted, see below                |

## The ladder

Rungs are counted in consecutive non-`ok` probes, so each is also a duration. At the default
2min interval:

| Failures | Elapsed | Action                                                          |
| -------- | ------- | --------------------------------------------------------------- |
| 1–2      | ≤4min   | Nothing. A single management blip is not worth a daemon restart |
| 3        | ~6min   | `systemctl restart netbird`, then re-run the routing oneshot    |
| 6        | ~12min  | `netbird down; netbird up`, then re-run the routing oneshot     |
| 12       | ~24min  | Reboot, if every guard passes                                   |

Only one rung fires per `netbird_watchdog_action_cooldown` (10min), so a repair gets several
probes to take effect before the next escalates on top of it. A single `ok` probe resets the
counter to zero.

The re-up rung deliberately carries **no** `--setup-key`. It re-applies the configuration already
on disk and cannot re-enrol a peer the account has forgotten.

### The reboot guards

All four must pass:

- `netbird_watchdog_reboot` is true. It defaults to true, because the nodes this exists for are
  the ones nobody can reach to reboot by hand. Set it false in `ansible/nodes/<host>/host.yml` to
  cap the ladder at re-up, which is worth doing while first observing a node.
- Uptime is above `netbird_watchdog_reboot_min_uptime` (30min). If the mesh is broken this soon
  after boot, another reboot is not what fixes it.
- No reboot within `netbird_watchdog_reboot_cooldown` (24h). The timestamp lives under
  `/var/lib`, so it survives the reboot it is guarding.
- The node has a default route. Without one, NetBird is a symptom and not the fault, and
  rebooting would take the node down without addressing it.

The reboot is the last thing the script does, after the state file, the metrics and the ping are
all written or delivered. Otherwise the reason for the reboot dies with the boot.

After a reboot the failure counter resets, so the ladder gets a fresh restart and re-up run. If
that also fails it climbs back to the reboot rung, the 24h cooldown blocks it, and the node goes
`stuck`.

## Stuck, and why no credential lives on a node

`stuck` is terminal by construction. The watchdog logs at ERROR, publishes
`futhark_mesh_state 3`, fails its healthchecks.io check, and then does nothing further.

What is left at that point is a peer the account no longer has, or a local configuration too
broken to re-up, and both need a NetBird credential to fix. None is on the node, deliberately.
`roles/netbird` mints a one-off, group-scoped setup key that expires in 300 seconds and hands it
to a single `netbird up`; storing a reusable key or the enrollment PAT on every node would make
each node a peer-enrollment credential at rest, permanently, to close a failure mode that ends in
a human either way. The recovery is a converge from the operator machine, over the node's other
route in.

That is the trade this design accepts: a node that loses its registration entirely stays down
until someone reaches it.

## Reporting

Three channels, in descending order of how much you can trust them during an actual outage.

**healthchecks.io.** Each node pings its own check over the public internet, the one path that
does not go through the thing being watched. A healthy probe pings the base URL, a repair posts
to `/log`, and `stuck` posts to `/fail`. The URL comes from `secrets.healthchecks[<hostname>]`,
one item with one field per node, resolved by `just ans render-secrets` and written to
`/etc/futhark/mesh-watchdog.env` at mode 0600. A node with no field still runs the ladder. It just
reports nothing. Replacing a ping URL is
[Credential rotation](../operations/rotation.md#the-healthchecksio-ping-urls).

**The journal.** `journalctl -u futhark-mesh-watchdog` on the node, with one line per unhealthy
probe and per action taken.

**Metrics.** `futhark_mesh_*`, written atomically to
`/var/lib/node_exporter/textfile_collector/futhark_mesh.prom` and picked up by node-exporter's
textfile collector, through the hostPath mount in
`infra/monitoring/app/exporters/node-exporter.yaml`. Rules in
`infra/monitoring/app/grafana/alerting/mesh.yaml` cover unhealthy, stuck, self-healed, and a
watchdog that has stopped running. These are second-class on purpose: they are scraped over the
mesh, so a hard failure takes this path down with it. What they add is the shape of a failure, and
notice of the repairs that worked, which otherwise leave no trace anywhere.

`futhark_mesh_repairs_total` is the one to watch over time. A node repairing itself is the system
working. A node repairing itself every day has an underlying fault the watchdog is papering
over.

## Tuning and testing

Every threshold is a default in `ansible/roles/netbird/defaults/main.yml`, overridable per node in
`ansible/nodes/<host>/host.yml`.

To exercise the ladder on a node, with a shell already open on a route that is not the mesh:

**This can reboot the node.** Set `netbird_watchdog_reboot: false` for that node first, and do it
on a worker before a controller.

```bash
systemctl stop netbird                    # the drop-in alone brings it back in ~10s
systemctl mask netbird; systemctl stop netbird   # the drop-in cannot act, so the ladder climbs
journalctl -fu futhark-mesh-watchdog
systemctl unmask netbird                  # before the reboot rung's window
```

Verify the recovery: `netbird status` reports connected, `futhark_mesh_state` returns to 0, and
the node's healthchecks.io check goes green within one probe interval.
