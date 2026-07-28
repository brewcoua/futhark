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

**Provider tokens are never committed, in any form.** A module's `secrets.sops.env` holds two
kinds of line, and neither is a value: identifying values that grant nothing — a real public IP,
the tailnet name, an account ID, as `TF_VAR_<name>=...` — and credentials as bare `pass://`
references that `pass-cli run` resolves after `sops exec-env` has loaded the file. No braces:
`run` resolves bare URIs and ignores braced ones, the inverse of `inject`. See
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
`task ops:setup`. `plan` and `apply` compose both stores, in this order:
`sops exec-env secrets.sops.env 'pass-cli run -- tofu <cmd>'`. That needs a Proton Pass session
(`pass-cli info`) and the GPG smartcard present; neither ever writes a value to disk.

### Values another plane owns

A module never keeps its own copy of a value that already lives somewhere else. It declares a
reference in `refs.env`, which `plan` and `apply` resolve before running:

```
# <variable>=<repo-relative .sops file>#<sops --extract expression>
TF_VAR_kenaz_public_ip=ansible/nodes/kenaz/host.sops.yml#["node_ip"]
TF_VAR_tailnet_domain=ansible/inventory/group_vars/all/secrets.sops.yml#["tailnet_domain"]
TF_VAR_int_domain=infra/substitutions/app/int-domain.sops.yaml#["stringData"]["INT_DOMAIN"]
```

The expression goes to `sops --extract` verbatim, so one line shape reaches a node fact, an
Ansible group_var and a Flux Secret alike. Who owns what:

| Value            | Owner                                               | Why                                                                                                            |
| ---------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| node addresses   | `ansible/nodes/<node>/host.sops.yml`                | `roles/tailscale` writes `node_mesh_ip` back into it after each tailnet join — recorded where it is discovered |
| `tailnet_domain` | `ansible/inventory/group_vars/all/secrets.sops.yml` | `roles/tailscale` needs it on every node                                                                       |
| `INT_DOMAIN`     | `infra/substitutions/app/int-domain.sops.yaml`      | Flux substitutes it into manifests                                                                             |

`refs.env` holds only references, so it is committed in the clear even though every file it
names is encrypted. All of them seal to the same operator key, so resolving one costs no extra
card touch. A module without the file is unaffected.

**A variable in both `refs.env` and `secrets.sops.env` is not a harmless duplicate.**
`sops exec-env` runs _after_ the refs are exported, so the encrypted copy wins and the ref is
silently dead. Keep each value in exactly one of the two.

`infra/substitutions/app/edge-ips.sops.yaml` is the reverse direction and keeps its own copy: Flux
decrypts it in-cluster, so it is sealed to the cluster age key as well, and `.sops.yaml`
deliberately keeps that key away from everything under `ansible/` and `tofu/`.

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

What each touches. Every arrow into a secret store is a read, except the one marked — that is
the whole read-only rule, and its single exception:

```d2
direction: down

pass: Proton Pass
sops: SOPS in git
infisical: Infisical

modules: "tofu/" {
  bunny
  oidc
  tailscale
}

pass -> modules: provider tokens\n(pass-cli run)
sops -> modules: identifying values\n(sops exec-env, refs.env)

modules.bunny -> bunny-api: DNS records
modules.tailscale -> ts-api: policy file + tests
modules.oidc -> pocketid: OIDC clients

bunny-api: Bunny DNS API
ts-api: Tailscale API
pocketid: "Pocket ID API\n(a Flux-managed workload)"

modules.oidc -> infisical: "WRITES the minted secret\nseparate identity, scoped to /nodes/<host>/<app>" {
  style: { bold: true; stroke: "#c00" }
}
```
