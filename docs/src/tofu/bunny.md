# bunny

Manages public DNS records against the existing Bunny DNS zone for `config/domain/domain.env`'s
`DOMAIN`. The zone is looked up via a data source, not created — cert-manager's DNS-01 webhook
already points at that same zone.

Two records, both defined in `dns.tf`:

- `auth.$DOMAIN` → the edge node's public IP. `traefik-edge` routes it to `infra/auth`, which
  is pinned to `ogma`.
- `vault.$INT_DOMAIN` → the edge node's Tailscale mesh IP. `traefik-internal` routes it to
  `infra/openbao`, also pinned to `ogma`. It resolves publicly to a CGNAT address
  (`100.64.0.0/10`), so it is only reachable from the tailnet.

```bash
task tf:init -- bunny
task tf:plan -- bunny
task tf:apply -- bunny
```

## Before the first apply

Populate the Proton Pass items `secrets.env` points at: the edge node's IP address, its mesh
IP, and a Bunny API key. The API key needs the same permissions as the one already used by
`infra/cert-manager`'s DNS-01 webhook — Bunny API keys are account-wide, not zone-scoped.
