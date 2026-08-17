# bunny

Manages public DNS records against the existing Bunny DNS zone for `$DOMAIN`. Applying it leaves
one `A` record per publicly exposed hostname, pointing at whichever node serves it.

The zone is looked up via a data source, not created, because cert-manager's DNS-01 webhook
already points at that same zone.

Three records are defined in `dns.tf`, and they point at two different hosts.

| Record         | Points at | Reached through                                         |
| -------------- | --------- | ------------------------------------------------------- |
| `auth.$DOMAIN` | `ogma`    | `traefik-edge`, to `infra/auth` pinned to the same node |
| `git.$DOMAIN`  | `brokkr`  | that node's own Traefik, to Forgejo                     |
| `ci.$DOMAIN`   | `brokkr`  | the same, to Woodpecker                                 |

`auth` never leaves the edge node, because the workload behind it is pinned there. `git` and `ci`
never touch the cluster at all: `brokkr` is outside it and terminates its own TLS. Their certificates
are issued over TLS-ALPN-01 rather than DNS-01, so unlike the cluster's wildcard nothing writes a
challenge record into this zone for them, and these two `A` records are all that has to exist here.
See [The standalone Podman plane](../gitops/podman.md#tls-without-cert-manager).

Both addresses come from the `nodes` map in `config/sops/ops.sops.yaml` through `refs.env`, as
separate variables. `brokkr` is not the edge node and never becomes it, so moving public ingress does
not move `git` and `ci`.

Add one `A` record block per edge-exposed hostname as each app lands. Every record carries
`prevent_destroy`.

Nothing here resolves under `$SUB_INTERNAL.$DOMAIN`. The only records the zone ever holds
under it are cert-manager's DNS-01 challenges for the internal wildcard certificate, written
and deleted by the ACME solver; the names themselves are answered on the mesh by
[`netbird`](netbird.md), which is what keeps an internal hostname from resolving to anything at
all off-mesh.

```bash
just tf init bunny
just tf plan bunny
just tf apply bunny
```

## Prerequisites

The `tofu.bunny` section of `config/sops/ops.sops.yaml` holds one line. The edge node's address comes from `refs.env`, which reads it
from the plane that owns it. Store a Bunny API key in Proton Pass and reference it as
`BUNNYNET_API_KEY: pass://<vault>/bunny/api key`. The API key needs the same permissions as the
one already used by `infra/cert-manager`'s DNS-01 webhook, because Bunny API keys are account-wide
rather than zone-scoped. That is also why rotating it moves both consumers at once:
[Credential rotation](../operations/rotation.md#the-bunny-api-key).

Verify: `just tf plan bunny` is a no-op after the apply, and each record resolves publicly with
`dig +short auth.$DOMAIN`, `dig +short git.$DOMAIN` and `dig +short ci.$DOMAIN`. The last two must
return `brokkr`'s address, not the edge node's.
