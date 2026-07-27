# Rules for every module

`tofu/` covers provider-API resources Flux and Kustomize cannot own, because they live outside
the cluster: a DNS record, a registrar account, a tailnet policy.

It is not used for anything Flux can reconcile. Pocket ID itself is a Flux-managed workload
under `infra/auth/`, not a tofu resource — the [`oidc`](oidc.md) module only registers its
OIDC clients, an operation against Pocket ID's own API that no Kustomization can express.

## Rules

**Read-only against the secret stores.** Never let a module write to one. Anything a module
_mints_ becomes a `sensitive` output, filed by hand.

_Exception: [`oidc`](oidc.md)._ It mints OIDC client secrets in Pocket ID, and the whole point
of the module is removing that hand-paste step for this one round trip, so it writes those
secrets straight to Infisical. It authenticates as a machine identity scoped to write one
folder — `/nodes/<hostname>/<app>` — and is deliberately not the read-only identity the cluster
uses. Every other module stays read-only.

**Provider tokens are never committed, in any form.** They come from Bitwarden via `bws run`,
which injects a project's secrets as environment variables named after the secrets themselves —
so a module needs no committed pointer at all. A module's `secrets.sops.env` holds only the
other category: values that _identify_ but grant nothing — a real public IP, the tailnet name,
an account ID — SOPS-encrypted, as `TF_VAR_<name>=...`. See
[Secrets](../conventions/secrets.md).

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
`task ops:setup`. `plan` and `apply` compose both stores:
`bws run -- 'sops exec-env secrets.sops.env "tofu <cmd>"'`. That needs `BWS_ACCESS_TOKEN`
exported and the GPG smartcard present; neither ever writes a value to disk.

The pre-commit `tofu-validate` hook only runs `fmt` and `validate`, never `init` — a hook that
touches `.terraform.lock.hcl` fails pre-commit's own "did this hook modify a file" check. Run
`task tf:init` once locally before committing. CI runs init as its own step first; see
[Checks and CI](../operations/checks.md).

## Modules

| Module                      | Manages                                                                           |
| --------------------------- | --------------------------------------------------------------------------------- |
| [`bunny`](bunny.md)         | Public DNS records in the existing Bunny DNS zone                                 |
| [`oidc`](oidc.md)           | Pocket ID OIDC clients, writing the minted secret into Infisical                  |
| [`tailscale`](tailscale.md) | The tailnet policy file, including the `ip-in-ip` rule the pod overlay depends on |
