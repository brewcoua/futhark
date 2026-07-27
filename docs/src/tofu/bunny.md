# bunny

Manages public DNS records against the existing Bunny DNS zone for `config/domain/domain.env`'s
`DOMAIN`. The zone is looked up via a data source, not created — cert-manager's DNS-01 webhook
already points at that same zone.

One record, defined in `dns.tf`:

- `auth.$DOMAIN` → the edge node's public IP. `traefik-edge` routes it to `infra/auth`, which
  is pinned to `ogma`.

```bash
task tf:init -- bunny
task tf:plan -- bunny
task tf:apply -- bunny
```

## Before the first apply

Fill in `secrets.sops.env` (from its `.example`) with the edge node's public and mesh
addresses, and store a Bunny API key in Bitwarden named `BUNNYNET_API_KEY`. The API key needs
the same permissions as the one already used by `infra/cert-manager`'s DNS-01 webhook — Bunny
API keys are account-wide, not zone-scoped.
