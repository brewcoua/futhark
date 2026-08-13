# The egress exporter

What publishes the cluster's public address as a metric, and why the lookup runs on the node
rather than in a pod. Read this before changing the Egress widget on Glance's network page, or if
that widget goes blank.

`ansible/roles/egress_exporter` runs on any node with `node.public_ingress`, under the `metrics`
tag. Nothing in it branches on a hostname.

## Why it is not a pod

The dashboard's Egress widget used to call `ifconfig.co` from the Glance pod. That answers with
the public address of whichever node the pod is scheduled on, which is not the node traffic
arrives at: both Traefik releases are pinned to the ingress node with a `nodeSelector`, and Glance
is not. The number displayed was real and belonged to the wrong host.

Asking from the ingress node itself removes the ambiguity, and there is already a channel for a
node to publish a fact about itself: the textfile collector, which
`ansible/roles/netbird` uses for the mesh watchdog's metrics.

## What runs

| Unit                               | Is                                                                    |
| ---------------------------------- | --------------------------------------------------------------------- |
| `/usr/local/bin/futhark-egress.sh` | Fetches `egress_exporter_url` and writes the metrics file             |
| `futhark-egress.service`           | `Type=oneshot`, runs the script                                       |
| `futhark-egress.timer`             | Every `egress_exporter_interval` (default `1h`), plus 1min after boot |

The script writes `futhark_egress_ip_info{ip,asn_org,country} 1` and
`futhark_egress_last_run_timestamp_seconds` to
`/var/lib/node_exporter/textfile_collector/futhark_egress.prom`. That directory is the hostPath
mounted into the node-exporter DaemonSet in
`infra/monitoring/app/exporters/node-exporter.yaml`; the path is spelled in
`egress_exporter_textfile_dir` and both spellings have to agree.

It writes to a temporary file in the same directory and moves it into place, because node-exporter
reads that directory on every scrape and would otherwise be able to read a half-written file.

A failed lookup exits non-zero and leaves the previous file untouched, rather than publishing an
empty one. A transient outage of the lookup service therefore reads as a stale address, not as the
address having gone away.

## Verify

On the node:

```bash
systemctl list-timers futhark-egress.timer
sudo /usr/local/bin/futhark-egress.sh
cat /var/lib/node_exporter/textfile_collector/futhark_egress.prom
```

The file should hold one `futhark_egress_ip_info` line with a non-empty `ip` label.

From a mesh device, confirm the series arrived:

```bash
curl -s "https://metrics.$SUB_INTERNAL.$DOMAIN/api/v1/query?query=futhark_egress_ip_info"
```

The address is a label value, not a sample value, so the sample is always `1` and the reading is
in the labels. That is also why the metric carries no address in this repository: it is produced
at runtime and never committed.
