# ogma.podman

`ogma` is a standalone Podman node (not part of the k0s cluster), running OpenBao — the secrets
backend for the whole fleet, replacing Infisical Cloud.

- `quadlets/` — Podman Quadlet units (`.container`/`.volume`), synced verbatim into
  `/etc/containers/systemd/` by the gitops-pull timer (`ansible/roles/gitops_pull`). This is the
  only writer of that directory; no Ansible role templates a unit.
- `config/openbao.hcl` — OpenBao server config (storage/listener). No secrets: TLS cert/key are
  host-mounted from `/etc/openbao/tls/`, generated on ogma's disk by `ansible/roles/openbao`, and
  never committed.

Reconciled every 5 minutes by `futhark-gitops-pull.timer` on ogma; push to `master` and it
converges on its own, or run `task bao:reconcile-now` for an immediate pull. See
`ansible/roles/openbao/` for one-time init/unseal/namespace bootstrap, and
`infra/external-secrets/README.md` for how the k0s cluster consumes secrets from here.
