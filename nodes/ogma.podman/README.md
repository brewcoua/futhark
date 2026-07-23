# ogma.podman

`ogma` is a standalone Podman node (not part of the k0s cluster), running OpenBao — the secrets
backend for the whole fleet — and Pocket ID + a standalone Traefik, the fleet's SSO/OIDC provider
(`auth.$DOMAIN`), deliberately kept off k0s so auth survives a cluster outage. `$DOMAIN`/
`$INT_DOMAIN` come from `infra/_components/domain/domain.env`, the same source Flux-managed apps
use — the gitops-pull script (`ansible/roles/gitops_pull`) substitutes them into `quadlets/` and
`config/` at deploy time (see below).

- `quadlets/` — Podman Quadlet units (`.container`/`.volume`), synced verbatim into
  `/etc/containers/systemd/` by the gitops-pull timer (`ansible/roles/gitops_pull`). This is the
  only writer of that directory; no Ansible role templates a unit.
- `config/` — non-secret support files for those units, installed to `/etc/<name>/config/` by the
  same timer (e.g. `config/openbao.hcl` -> `/etc/openbao/config/openbao.hcl`).
  - `openbao.hcl` — OpenBao server config (storage/listener). TLS cert/key are host-mounted from
    `/etc/openbao/tls/`, generated on ogma's disk by `ansible/roles/openbao`, and never committed.
  - `traefik.yml` — Traefik static config (entrypoint, Docker/podman-socket provider, Bunny
    DNS-01 resolver). The Bunny API key is host-mounted via `/etc/traefik/env`, provisioned by
    `ansible/roles/pocketid`, and never committed.

Traefik discovers containers only via labels (`exposedByDefault: false`), read off the rootful
podman socket (`/run/podman/podman.sock`):

- Pocket ID (`pocketid.container`) — routed at `auth.$DOMAIN` with a Let's Encrypt cert from Bunny
  DNS-01. `tofu/bunny/dns.tf` points `auth.$DOMAIN` straight at ogma's own public IP.
- OpenBao (`openbao.container`) — routed at `vault.$INT_DOMAIN` on a tailnet-only entryPoint
  (`traefik.yml`'s `vault` entryPoint, bound to `$TAILNET_IP`), TLS passthrough since OpenBao
  terminates its own self-signed cert (the one ESO trusts) rather than Traefik.

Reconciled every 5 minutes by `futhark-gitops-pull.timer` on ogma; push to `master` and it
converges on its own, or run `task bao:reconcile-now` for an immediate pull. See
`ansible/roles/openbao/` for one-time init/unseal/namespace bootstrap, `ansible/roles/pocketid/`
for Pocket ID/Traefik secret provisioning, and `infra/external-secrets/README.md` for how the k0s
cluster consumes secrets from OpenBao.
