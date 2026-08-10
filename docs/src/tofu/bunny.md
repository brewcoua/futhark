# bunny

Manages public DNS records against the existing Bunny DNS zone for `$DOMAIN`. Applying it leaves
one `A` record per edge-exposed hostname pointing at the edge node.

The zone is looked up via a data source, not created, because cert-manager's DNS-01 webhook
already points at that same zone.

One record is defined in `dns.tf`: `auth.$DOMAIN`, pointing at the edge node's public IP.
`traefik-edge` routes it to `infra/auth`, which is pinned to the same node, so the request never
leaves it. Add one `A` record block per edge-exposed hostname as each app lands.

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

Verify: `just tf plan bunny` is a no-op after the apply, and the record resolves publicly with
`dig +short auth.$DOMAIN`.
