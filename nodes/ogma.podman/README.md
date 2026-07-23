# ogma.podman

`ogma` is a standalone Podman node (not part of the k0s cluster), running OpenBao — the secrets
backend for the whole fleet — and Pocket ID + a standalone Traefik, the fleet's SSO/OIDC provider
(`auth.brewen.dev`), deliberately kept off k0s so auth survives a cluster outage.

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

Traefik discovers Pocket ID (and only Pocket ID — `exposedByDefault: false`) via labels on
`pocketid.container`, read off the rootful podman socket (`/run/podman/podman.sock`), and routes
`auth.brewen.dev` to it with a Let's Encrypt cert from Bunny DNS-01. `tofu/bunny/dns.tf` points
`auth.brewen.dev` straight at ogma's own public IP.

Reconciled every 5 minutes by `futhark-gitops-pull.timer` on ogma; push to `master` and it
converges on its own, or run `task bao:reconcile-now` for an immediate pull. See
`ansible/roles/openbao/` for one-time init/unseal/namespace bootstrap, `ansible/roles/pocketid/`
for Pocket ID/Traefik secret provisioning, and `infra/external-secrets/README.md` for how the k0s
cluster consumes secrets from OpenBao.
