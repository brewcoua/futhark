# Checks and CI

## Pre-commit

`just ops hooks` installs them; `pre-commit run --all-files` runs everything by hand.

| Hook                              | Scope                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------ |
| `gitleaks`                        | Secret scanning                                                                      |
| `prettier`                        | Markdown, JSON, YAML formatting                                                      |
| `yamllint`                        | `.yamllint.yml`: 120-column warning, sequences indented, document-start off          |
| whitespace and encoding           | Trailing whitespace, final newline, BOM, mixed line endings, CRLF, tabs, smartquotes |
| `check-added-large-files`         | 2048 KB ceiling                                                                      |
| `check-executables-have-shebangs` |                                                                                      |
| `ansible-lint`                    | `ansible/` only                                                                      |
| `kustomize-build`                 | Every `kustomization.yaml` under `flux/`, `infra/`, `nodes/`, with `--enable-helm`   |
| `just-fmt`                        | `just --fmt --check` on the root `justfile` and each `.just/*.just`                  |
| `tofu-validate`                   | `tofu fmt -check -diff` and `tofu validate` per module                               |
| `sops-encrypted`                  | Every `*.sops.{yaml,yml,env,json}` actually contains ciphertext                      |

Five of these have a wrinkle worth knowing.

**`just-fmt` checks each file as its own root.** `just --fmt` formats one file at a time and
does not follow `mod`, so the hook passes every justfile explicitly. It is still gated behind
`--unstable`, and `validate.yml` installs the `JUST_VERSION` pin because the runner image ships
no `just`.

**`sops-encrypted` greps, it does not decrypt.** It looks for an `ENC[` marker and nothing else,
so it needs no key and runs identically on a runner and on your laptop. It exists for one
failure mode: writing a `*.sops.yaml` and committing it before running `sops -e -i`. `gitleaks`
will not reliably catch that, because a node address or a domain matches no credential pattern —
which is exactly the class of value those files hold. `.gitleaks.toml` allowlists the same paths,
since SOPS ciphertext otherwise trips the entropy rules on every commit.

**`tofu-validate` deliberately does not run `tofu init`.** `init` can touch
`.terraform.lock.hcl`, and pre-commit treats a hook that modifies a tracked file as a failure.
So run `just tf init` once locally before committing a `.tf` change, or validate fails on an
uninitialized module. CI runs init as its own step instead.

**`ansible-lint` needs `always_run: false` set explicitly.** Upstream's own hook manifest sets
`always_run: true`, which overrides the `files: ^ansible/` scoping — without the override it
runs on every commit regardless of what changed.

**The `gitleaks` hook only scans the staged index** (`--staged`), which is empty under
`pre-commit run --all-files`. Locally that is the right behaviour; in CI it silently scans
nothing, which is why `validate.yml` runs a separate full-tree `gitleaks dir .`.

## CI

Three workflows, all in `.github/workflows/`.

**`validate.yml`** runs on every pull request and every push to `master`, with
cancel-in-progress concurrency. Two jobs:

- `pre-commit` — installs kustomize and helm explicitly (neither ships on the runner image,
  and both are `language: system` hooks), runs `tofu init -backend=false` per module, then
  `pre-commit run --all-files`, then the full-tree gitleaks scan described above.
- `ansible-syntax` — installs the galaxy collections and runs
  `ansible-playbook --syntax-check playbooks/*.yml`.

**`docs.yml`** builds this book with mdbook on every pull request and push, and deploys it to
GitHub Pages only from `master`. It then asserts that every ` ```d2 ` fence in `docs/src`
became a rendered diagram. That check is not redundant: if `d2` or `mdbook-d2` is missing,
mdbook leaves the fence as a code block and still exits 0, so the diagrams would silently
stop shipping.

**`mirror.yml`** pushes a full mirror to Codeberg on every push to `master`, daily on a cron,
and on demand. It is disaster recovery, not a second remote you push to. It uses
`ssh-keyscan` for the host key, which is trust-on-first-use — Codeberg publishes no
authenticated equivalent to GitHub's `api.github.com/meta`. The blast radius is this mirror
push only, not the live Flux deploy-key channel.

All three workflows check out with `persist-credentials: false`, and every version they install
is pinned — in `config/versions.env`, the same file `just ops deps` reads, so a local
`just docs build` renders with the mdbook CI publishes and pre-commit runs the kustomize CI
installs. Both sides consume it natively: just via `set dotenv-path` in the root `justfile`,
whose values every submodule inherits, and the workflows via
`grep -v '^#' config/versions.env >> "$GITHUB_ENV"`. It is dotenv rather than YAML for the same
reason `config/domain/domain.env` is — nothing in it nests, and parsing YAML would mean a `yq`
dependency inside the very recipe whose job is installing dependencies.

CI holds no decryption key and must never need one. Nothing above decrypts: `kustomize build`
parses SOPS output fine, because SOPS encrypts values and leaves keys alone, and
`sops-encrypted` only greps. `ansible-playbook --syntax-check` is the exception to watch — it
loads vars plugins, so `community.sops` will try to open `group_vars`/`host_vars`. Keep that
non-fatal in CI rather than putting a key into GitHub Actions.

## Infisical tier isolation

Two manual checks, in the same spirit as the `ip-in-ip` test in
[tailscale](../tofu/tailscale.md). Neither is automated, and both are worth re-running after any
change to the operator HelmReleases or the admission policy — they are the only evidence the
tier boundary is real rather than merely intended. Run them once at the end of
[Cold bootstrap](setup.md), and delete the objects afterwards.

**RBAC.** Create an `InfisicalStaticSecret` in `actual` (a `futk.eu/tier: node` namespace) whose
`targets[0].namespace` is `monitoring`. The object is admitted — the policy below only pins
targets to the object's own namespace, and this one violates that, so in practice admission
catches it first. To test RBAC on its own, add a second namespace to the node tier's
`scopedNamespaces`, point a target at it, and confirm the operator writes there; then remove it
and confirm the write starts failing with a `forbidden` error in the operator's logs.

**Admission.** In `actual`, create one with `sources[0].secretPath: /infra/cert-manager`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: secrets.infisical.com/v1beta1
kind: InfisicalStaticSecret
metadata:
  name: isolation-probe
  namespace: actual
spec:
  infisicalAuthRef: {name: infisical, namespace: infisical-node-kenaz}
  sources:
    # Spelled out because this bypasses kustomize; a committed manifest gets both
    # from config/infisical instead.
    - projectSlug: futharkd
      environmentSlug: prod
      secretPath: /infra/cert-manager
  targets:
    - kind: Secret
      name: isolation-probe
      namespace: actual
      creationPolicy: Owner
  syncOptions:
    refreshInterval: 1m
EOF
```

The API server must reject this at admission with `secretPath must lie within the namespace's
own tier`. If it is created instead, the `ValidatingAdmissionPolicyBinding` is not selecting the
namespace — check that `actual` still carries `futk.eu/tier` and `futk.eu/node`.
