# Rules for every module

`tofu/` covers provider-API resources Flux and Kustomize cannot own, because they live outside
the cluster: a DNS record, a registrar account, a tailnet policy.

It is not used for anything Flux can reconcile. Pocket ID itself is a Flux-managed workload
under `infra/auth/`, not a tofu resource — the [`oidc`](oidc.md) module only registers its
OIDC clients, an operation against Pocket ID's own API that no Kustomization can express.

## Rules

**Read-only against OpenBao.** Never let a module write to OpenBao. Anything a module _mints_
becomes a `sensitive` output, pasted into OpenBao by hand.

_Exception: [`oidc`](oidc.md)._ It mints OIDC client secrets in Pocket ID, and the whole point
of the module is removing that hand-paste step for this one round trip, so it writes those
secrets straight to OpenBao via the `vault` provider. It is scoped to the `oidc-writer` policy
— write-only on `secret/data/*` in one namespace, created by
`ansible/roles/openbao/tasks/namespaces.yml` — never the root token. Every other module stays
read-only.

**Provider tokens are never committed.** A module's `secrets.env` holds only Proton Pass
`pass://` pointers, which are safe to commit, resolved at runtime by
`pass-cli run --env-file`. This also covers _identifying_ values that are not credentials but
still should not sit in git — a real public IP, the tailnet name. Set those as
`TF_VAR_<name>=pass://...`.

A genuinely non-identifying constant that is also shared with other parts of the repo — the
domain — is read straight from its committed source, `config/domain/domain.env`, as a `local`
rather than duplicated into `terraform.tfvars`. See [Domains](../conventions/domains.md).

**State stays local and gitignored.** `tofu/**/.terraform/`, `tofu/**/*.tfstate*` and
`tofu/**/crash.log` are all excluded. A module's minted credentials can sit in state in
plaintext even when marked `sensitive` — that only suppresses console and plan output. Keep
state on the operator machine. `.terraform.lock.hcl` is the provider version lockfile and
**is** committed.

**Verify provider resource and attribute names** against current provider docs before the
first apply.

## Running a module

```bash
task tf:init [-- <module>]   # no secrets needed, provider download only
task tf:plan -- <module>
task tf:apply -- <module>
```

`task tf:init` with no module argument inits every module under `tofu/`, and runs as part of
`task ops:setup`. `plan` and `apply` wrap `pass-cli run --env-file secrets.env -- tofu <cmd>`.

The pre-commit `tofu-validate` hook only runs `fmt` and `validate`, never `init` — a hook that
touches `.terraform.lock.hcl` fails pre-commit's own "did this hook modify a file" check. Run
`task tf:init` once locally before committing. CI runs init as its own step first; see
[Checks and CI](../operations/checks.md).

## Modules

| Module                      | Manages                                                                           |
| --------------------------- | --------------------------------------------------------------------------------- |
| [`bunny`](bunny.md)         | Public DNS records in the existing Bunny DNS zone                                 |
| [`oidc`](oidc.md)           | Pocket ID OIDC clients, writing the minted secret into OpenBao                    |
| [`tailscale`](tailscale.md) | The tailnet policy file, including the `ip-in-ip` rule the pod overlay depends on |
