# OpenTofu — the cloud plane

Provider-API resources that Flux/Kustomize can't own, because they live outside the cluster (a DNS
record, a registrar/CDN account). Not used for anything Flux can reconcile — Authentik's own config
is blueprints (`infra/authentik/README.md`), not Tofu, for exactly that reason.

## Rules for any module here

- Read-only against Infisical if it needs to read anything from there at all; never let a module
  write to Infisical. Anything a module _mints_ becomes a `sensitive` output, pasted into Infisical
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

Manages public DNS records for edge-exposed apps (`auth.DOMAIN` for `infra/authentik` today) against
the existing `brewen.dev` zone in Bunny DNS — looked up via a data source, not created, since
cert-manager's DNS-01 webhook already points at that same zone.

```bash
cd tofu/bunny
pass-cli run --env-file secrets.env -- tofu init
pass-cli run --env-file secrets.env -- tofu plan
pass-cli run --env-file secrets.env -- tofu apply
```

(`task tofu:plan` / `task tofu:apply` wrap this — see `.taskfiles/tofu/Taskfile.yaml`.)

Before the first apply: populate the two Proton Pass items `secrets.env` points at —
`futharkd/kenaz/public-ip` and `futharkd/bunny/api-key` (same permissions as the key already used by
`infra/cert-manager`'s DNS-01 webhook — Bunny API keys are account-wide, not zone-scoped).
