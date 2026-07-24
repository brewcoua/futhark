# OpenTofu — the cloud plane

Provider-API resources that Flux/Kustomize can't own, because they live outside the cluster (a DNS
record, a registrar/CDN account). Not used for anything Flux can reconcile — Pocket ID isn't a
Tofu-managed resource either, it's a Podman Quadlet reconciled by `ansible/roles/gitops_pull`
(see `nodes/ogma.podman/README.md`), for exactly that reason.

## Rules for any module here

- Read-only against OpenBao if it needs to read anything from there at all; never let a module
  write to OpenBao — anything a module _mints_ becomes a `sensitive` output, pasted into OpenBao
  by hand. **Exception: `oidc`.** It mints OIDC client secrets in Pocket ID and the whole point
  is removing that hand-paste step for this one round trip, so it's allowed to write those
  secrets straight to OpenBao via the `vault` provider, using the same root-token auth ansible
  already uses for namespace bootstrap (Proton Pass `futharkd/openbao/root token`, no narrower
  policy). Every other module stays read-only.
- Provider tokens are never committed. A module's `secrets.env` holds only Proton Pass `pass://`
  **pointers** (safe to commit) resolved at runtime by `pass-cli run --env-file`. This also covers
  _identifying_ values that aren't credentials but still shouldn't sit in git in plaintext (a real
  public IP — the same thing `REPLACE_WITH_PUBLIC_IP` guards against in
  `infra/traefik-edge/app/helmrelease.yaml`) — set those as `TF_VAR_<name>=pass://...`. A
  genuinely non-identifying constant that's also shared with other parts of the repo (the domain
  name) is read straight from its committed source (`infra/_components/domain/domain.env`) as a
  `local`, rather than duplicated into `terraform.tfvars`.
- State stays local and gitignored (`tofu/**/.terraform/`, `tofu/**/*.tfstate*`) — a module's minted
  credentials can sit in it in plaintext even when marked `sensitive` (that only suppresses
  console/plan output). Keep it on the operator machine.
- Verify provider resource/attribute names against current provider docs before the first apply.

## bunny

Manages public DNS records against the existing zone in Bunny DNS for
`infra/_components/domain/domain.env`'s `DOMAIN` — looked up via a data source, not created, since
cert-manager's DNS-01 webhook already points at that same zone.

- `auth.DOMAIN` — Pocket ID, ogma's public IP.
- `vault.INT_DOMAIN` — OpenBao, ogma's Tailscale mesh IP. Resolves publicly to a CGNAT
  (`100.64.0.0/10`) address, so it's only reachable from the tailnet.

```bash
cd tofu/bunny
tofu init  # no secrets needed, provider download only
pass-cli run --env-file secrets.env -- tofu plan
pass-cli run --env-file secrets.env -- tofu apply
```

(`task tofu:init [-- bunny]` / `task tofu:plan -- bunny` / `task tofu:apply -- bunny` wrap this —
see `.taskfiles/tofu/Taskfile.yaml`. `task tofu:init` with no module inits every module under
`tofu/`, and runs as part of `task ops:setup`.)

The pre-commit `tofu-validate` hook only runs `fmt`/`validate`, not `init` — a hook that touches
`.terraform.lock.hcl` fails pre-commit's own "did this hook modify a file" check. Run
`task tofu:init` once locally before committing; CI runs init as its own step first.

Before the first apply: populate the Proton Pass items `secrets.env` points at —
`futharkd/kenaz/public-ip`, `futharkd/ogma/ip address`, and `futharkd/bunny/api-key` (same
permissions as the key already used by `infra/cert-manager`'s DNS-01 webhook — Bunny API keys are
account-wide, not zone-scoped).

## oidc

See `tofu/oidc/README.md`.
