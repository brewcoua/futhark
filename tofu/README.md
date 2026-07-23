# OpenTofu — the cloud plane

Provider-API resources that Flux/Kustomize can't own, because they live outside the cluster (a DNS
record, a registrar/CDN account). Not used for anything Flux can reconcile — Pocket ID isn't a
Tofu-managed resource either, it's a Podman Quadlet reconciled by `ansible/roles/gitops_pull`
(see `nodes/ogma.podman/README.md`), for exactly that reason.

## Rules for any module here

- Read-only against OpenBao if it needs to read anything from there at all; never let a module
  write to OpenBao. Anything a module _mints_ becomes a `sensitive` output, pasted into OpenBao
  by hand.
- Provider tokens are never committed. A module's `secrets.env` holds only Proton Pass `pass://`
  **pointers** (safe to commit) resolved at runtime by `pass-cli run --env-file`. This also covers
  _identifying_ values that aren't credentials but still shouldn't sit in git in plaintext (a real
  public IP — the same thing `REPLACE_WITH_PUBLIC_IP` guards against in
  `infra/traefik-edge/app/helmrelease.yaml`) — set those as `TF_VAR_<name>=pass://...`. Only a
  genuinely non-identifying constant (a domain name, already public via `infra/_components/domain`)
  belongs in a plain, committed `terraform.tfvars`.
- State stays local and gitignored (`tofu/**/.terraform/`, `tofu/**/*.tfstate*`) — a module's minted
  credentials can sit in it in plaintext even when marked `sensitive` (that only suppresses
  console/plan output). Keep it on the operator machine.
- Verify provider resource/attribute names against current provider docs before the first apply.

## bunny

Manages public DNS records for edge-exposed apps (`auth.DOMAIN` for Pocket ID on `ogma` today)
against the existing `brewen.dev` zone in Bunny DNS — looked up via a data source, not created,
since cert-manager's DNS-01 webhook already points at that same zone.

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
