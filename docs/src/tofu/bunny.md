# bunny

Manages public DNS records against the existing Bunny DNS zone for `config/domain/domain.env`'s
`DOMAIN`. The zone is looked up via a data source, not created — cert-manager's DNS-01 webhook
already points at that same zone.

One record, defined in `dns.tf`: `auth.$DOMAIN` → the edge node's public IP. `traefik-edge`
routes it to `infra/auth`, which is pinned to `ogma`. One `A` record per edge-exposed hostname;
add a block as each app lands.

`$INT_DOMAIN` has a Bunny zone too, and this module deliberately holds nothing in it. The zone
exists so cert-manager can solve DNS-01 for the internal wildcard certificate; the names
themselves are answered on the mesh by [`netbird`](netbird.md), which is what keeps an internal
hostname from resolving to anything at all off-mesh.

```bash
just tf init bunny
just tf plan bunny
just tf apply bunny
```

## Before the first apply

`secrets.sops.env` holds one line. The edge node's address comes from `refs.env`, which reads it
from the plane that owns it. Store a Bunny
API key in Proton Pass and reference it as
`BUNNYNET_API_KEY=pass://futharkd/bunny/api key`. The API key needs
the same permissions as the one already used by `infra/cert-manager`'s DNS-01 webhook — Bunny
API keys are account-wide, not zone-scoped.
