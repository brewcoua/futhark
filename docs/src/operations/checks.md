# Checks and CI

What is checked automatically, what is not, and the manual checks that have no automation behind
them. Read this before adding a hook or wondering why CI passed something it should have caught.

## Pre-commit

Install the hooks once per clone:

```bash
just ops hooks
```

Run everything by hand:

```bash
pre-commit run --all-files
```

The hooks, from `.pre-commit-config.yaml`:

| Hook                              | Scope                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------ |
| `gitleaks`                        | Secret scanning                                                                      |
| `prettier`                        | Markdown, JSON, YAML formatting                                                      |
| `yamllint`                        | `.yamllint.yml`: 120-column warning, sequences indented, document-start off          |
| whitespace and encoding           | Trailing whitespace, final newline, BOM, mixed line endings, CRLF, tabs, smartquotes |
| `check-merge-conflict`            | Conflict markers                                                                     |
| `check-added-large-files`         | 2048 KB ceiling                                                                      |
| `check-executables-have-shebangs` |                                                                                      |
| `ansible-lint`                    | `ansible/` only                                                                      |
| `kustomize-build`                 | Every `kustomization.yaml` under `flux/`, `infra/`, `nodes/`, with `--enable-helm`   |
| `just-fmt`                        | `just --fmt --check` on the root `justfile` and each `.just/*.just`                  |
| `tofu-validate`                   | `tofu fmt -check -diff` and `tofu validate` per module                               |
| `sops-encrypted`                  | Every `*.sops.{yaml,yml,env,json}` actually contains ciphertext                      |

Five have a wrinkle worth knowing.

**`just-fmt` checks each file as its own root.** `just --fmt` formats one file at a time and does
not follow `mod`, so the hook passes every justfile explicitly. It is still gated behind
`--unstable`, and `validate.yml` installs the `JUST_VERSION` pin because the runner image ships no
`just`.

**`sops-encrypted` greps, it does not decrypt.** It looks for an `ENC[` marker and nothing else,
so it needs no key and runs identically on a runner and on your laptop. It exists for one failure
mode: writing a `*.sops.yaml` and committing it before running `sops -e -i`. `gitleaks` will not
reliably catch that, because a node address or a domain matches no credential pattern, which is
exactly the class of value those files hold. `.gitleaks.toml` allowlists the same paths, since
SOPS ciphertext otherwise trips the entropy rules on every commit. The root `.sops.yaml` is
excluded: it holds recipients, not ciphertext, and matches the filename pattern by accident.

**`tofu-validate` deliberately does not run `tofu init`.** `init` can touch
`.terraform.lock.hcl`, and pre-commit treats a hook that modifies a tracked file as a failure. Run
`just tf init` once locally before committing a `.tf` change, or validate fails on an
uninitialized module. CI runs init as its own step instead, with `-backend=false`, which is also
why a module with a remote backend needs no credentials in CI.

**`ansible-lint` needs `always_run: false` set explicitly.** Upstream's own hook manifest sets
`always_run: true`, which overrides the `files: ^ansible/` scoping. Without the override it runs
on every commit regardless of what changed.

**The `gitleaks` hook only scans the staged index** (`--staged`), which is empty under
`pre-commit run --all-files`. Locally that is the right behaviour. In CI it silently scans
nothing, which is why `validate.yml` runs a separate full-tree `gitleaks dir .`.

## CI

Four workflows, all in `.github/workflows/`.

**`validate.yml`** runs on every pull request and every push to `master`, with
cancel-in-progress concurrency. Three jobs:

- `pre-commit` installs kustomize and helm explicitly, since neither ships on the runner image and
  both are `language: system` hooks. It then runs `tofu init -backend=false` per module,
  `pre-commit run --all-files`, and the full-tree gitleaks scan described above.
- `renovate-config` runs `renovate-config-validator --strict`. A malformed `renovate.json5` is
  otherwise silent: Renovate skips the repository at 03:00 and updates just stop arriving.
- `ansible-syntax` installs the galaxy collections and runs
  `ansible-playbook --syntax-check playbooks/*.yml`.

**`docs.yml`** builds this book with mdbook on every pull request and push, and deploys it to
GitHub Pages only from `master`. It then asserts that every ` ```d2 ` fence in `docs/src` became a
rendered diagram. That check is not redundant: if `d2` or `mdbook-d2` is missing, mdbook leaves
the fence as a code block and still exits 0, so the diagrams would silently stop shipping.

**`renovate.yml`** runs Renovate at 03:00, on a change to its own config, and on demand. That is
an hour before the mirror cron, so an automerged update reaches Codeberg the same night. What it
covers and what it may merge is [Dependency updates](../conventions/updates.md).

**`mirror.yml`** pushes a full mirror to Codeberg on every push to `master`, daily on a cron, and
on demand. It is disaster recovery, not a second remote you push to. It uses `ssh-keyscan` for the
host key, which is trust-on-first-use, because Codeberg publishes no authenticated equivalent to
GitHub's `api.github.com/meta`. The blast radius is this mirror push only, not the live Flux
deploy-key channel.

All four workflows check out with `persist-credentials: false`, and every version they install is
pinned in `config/versions.env`, the same file `just ops deps` reads. A local `just docs build`
therefore renders with the mdbook CI publishes, and pre-commit runs the kustomize CI installs.
Both sides consume the file natively: `just` via `set dotenv-path` in the root `justfile`, whose
values every submodule inherits, and the workflows via
`grep -v '^#' config/versions.env >> "$GITHUB_ENV"`. It is dotenv rather than YAML because nothing
in it nests, and parsing YAML would mean a `yq` dependency inside the very recipe whose job is
installing dependencies.

**CI holds no decryption key and must never need one.** Nothing above decrypts: `kustomize build`
parses SOPS output fine, because SOPS encrypts values and leaves keys alone, and `sops-encrypted`
only greps. `ansible-playbook --syntax-check` parses playbooks without templating inventory
variables, so the `file` lookups in `group_vars/all/` are never evaluated and the missing
`ansible/.generated/` files do not fail it. Keep it that way rather than putting a key into GitHub
Actions.

## Infisical tier isolation

Two manual checks. Neither is automated, and both are worth re-running after any change to the
operator HelmReleases or the admission policy. They are the only evidence the tier boundary is
real rather than merely intended. Run them once at the end of [Cold bootstrap](setup.md), and
delete the objects afterwards.

### RBAC

Create an `InfisicalStaticSecret` in `actual`, a `futk.eu/tier: node` namespace, whose
`targets[0].namespace` is `monitoring`. The object is admitted, because the admission policy below
pins targets to the object's own namespace and this one violates that, so admission catches it
first.

To test RBAC on its own, add a second namespace to the node tier's `scopedNamespaces`, point a
target at it, and confirm the operator writes there. Then remove it and confirm the write starts
failing with a `forbidden` error in the operator's logs.

### Admission

In `actual`, create one with `sources[0].secretPath: /infra/cert-manager`:

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

The API server must reject this at admission with `secretPath must lie within the namespace's own
tier`. If it is created instead, the `ValidatingAdmissionPolicyBinding` is not selecting the
namespace. Check that `actual` still carries `futk.eu/tier` and `futk.eu/node`.

Clean up:

```bash
kubectl -n actual delete infisicalstaticsecret isolation-probe --ignore-not-found
```

## The per-node mesh checks

One healthchecks.io check per mesh node, pinged directly by that node's watchdog rather than by
anything in the cluster. See [The mesh watchdog](../ansible/mesh-watchdog.md). This is the only
mesh-health signal that does not travel over the mesh, which is the point: everything scraped into
Grafana goes dark exactly when the thing being watched breaks.

Read a red check as "this node has been unhealthy for longer than the grace period, and its own
repairs have not fixed it yet". The `/log` events on the check's timeline say which rungs fired. A
`/fail` means the ladder is exhausted and the node needs re-enrolling by hand.

This is distinct from the cluster-wide dead-man's switch in
`infra/monitoring/app/grafana/alerting/watchdog.yaml`, which pings from inside Grafana and so
reports on the cluster, not on the mesh underneath it.

## NetBird token expiry

NetBird Personal Access Tokens expire, 365 days out at most. Two are in use, one on each of the
two service users:

| Token                | Referenced from           | Breaks when it expires                             |
| -------------------- | ------------------------- | -------------------------------------------------- |
| `netbird-policy`     | `tofu.netbird`            | `just tf plan netbird` fails with a 401            |
| `netbird-enrollment` | `ansible.secrets.netbird` | A node join fails at "Mint a single-use setup key" |

Neither takes the mesh down when it lapses. Peers keep their configuration and keep connecting.
What stops is changing anything: no policy applies, and no new node joins.

Nothing in this repository tracks the expiry dates. Put them in a calendar when you issue the
tokens. The replacement procedure is
[Credential rotation](rotation.md#the-netbird-tokens).

## What has no check at all

Worth stating, because the absence is easy to mistake for coverage:

- **NetBird policy.** There are no server-side policy tests, so a wrong rule applies cleanly and
  fails later, in traffic. The [isolating test](../ansible/networking.md#the-isolating-test) is
  the substitute.
- **Credential expiry.** Nothing watches it. See above.
- **Backups that copied nothing.** A backup with zero volumes still reports `Completed`.
  `just bak describe <backup>` is the check, and the 26h alert in
  `infra/monitoring/app/grafana/alerting/backup.yaml` is the backstop. See
  [Backup and recovery](recovery.md).
