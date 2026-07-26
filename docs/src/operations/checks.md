# Checks and CI

## Pre-commit

`task ops:hooks` installs them; `pre-commit run --all-files` runs everything by hand.

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
| `tofu-validate`                   | `tofu fmt -check -diff` and `tofu validate` per module                               |

Three of these have a wrinkle worth knowing.

**`tofu-validate` deliberately does not run `tofu init`.** `init` can touch
`.terraform.lock.hcl`, and pre-commit treats a hook that modifies a tracked file as a failure.
So run `task tf:init` once locally before committing a `.tf` change, or validate fails on an
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
GitHub Pages only from `master`.

**`mirror.yml`** pushes a full mirror to Codeberg on every push to `master`, daily on a cron,
and on demand. It is disaster recovery, not a second remote you push to. It uses
`ssh-keyscan` for the host key, which is trust-on-first-use — Codeberg publishes no
authenticated equivalent to GitHub's `api.github.com/meta`. The blast radius is this mirror
push only, not the live Flux deploy-key channel.

All three workflows check out with `persist-credentials: false`, and every version they
install is pinned.
