# bunny

Manages public DNS records against the existing Bunny DNS zone for `config/domain/domain.env`'s
`DOMAIN`. The zone is looked up via a data source, not created — cert-manager's DNS-01 webhook
already points at that same zone.

Two records, defined in `dns.tf`:

- `auth.$DOMAIN` → the edge node's public IP. `traefik-edge` routes it to `infra/auth`, which
  is pinned to `ogma`. One `A` record per edge-exposed hostname; add a block as each app lands.
- `*.$INT_DOMAIN` → `CNAME` to `internal.$TAILNET`, the MagicDNS name of the tailnet device the
  tailscale operator creates for `traefik-internal`. One wildcard covers every internal app
  (`dash`, `logs`, `metrics`, …), so internal apps need no apply here.

The internal side is a CNAME rather than an `A` to the device's tailnet IP because the operator
assigns that IP and nothing in this repo holds it — an `A` record would drift the way
the `edge-ips` Secret's `MESH_IP` did. Only tailnet resolvers answer a `*.ts.net` name, so off-tailnet the
wildcard dead-ends; on-tailnet, a hostname with no matching Traefik router gets a 404 from
`traefik-internal`.

```bash
just tf init bunny
just tf plan bunny
just tf apply bunny
```

## Before the first apply

`secrets.sops.env` holds one line. The edge node's address, the tailnet suffix and the internal
base domain all come from `refs.env`, which reads each from the plane that owns it. Store a Bunny
API key in Proton Pass and reference it as
`BUNNYNET_API_KEY=pass://futharkd/bunny/api key`. The API key needs
the same permissions as the one already used by `infra/cert-manager`'s DNS-01 webhook — Bunny
API keys are account-wide, not zone-scoped.
