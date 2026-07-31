# Dependency updates

Every version in this repo is pinned exactly ([Version pins](layout.md#version-pins)), which is
only sustainable if something else does the watching. Renovate reads the whole tree once a night
and opens a pull request per update; the [Dependency Dashboard][dash] issue lists everything it
knows about, including updates it has not opened a PR for yet.

[dash]: https://docs.renovatebot.com/key-concepts/dashboard/

Config lives in `.github/renovate.json5`. It runs from `.github/workflows/renovate.yml` — this is
a self-hosted Renovate, not the Mend-hosted GitHub App, so no third party holds write access to
the repo.

## What it covers

| Manager                    | Reaches                                                                      |
| -------------------------- | ---------------------------------------------------------------------------- |
| `flux`                     | `HelmRelease` chart versions and the images inside their `values`            |
| `kubernetes`               | Images in plain manifests under `infra/` and `nodes/`                        |
| `terraform`                | `tofu/*/provider.tf` constraints and `.terraform.lock.hcl`                   |
| `ansible-galaxy`           | `ansible/requirements.yml`                                                   |
| `github-actions`           | Action pins in every workflow                                                |
| `pre-commit`               | Hook `rev:`s in `.pre-commit-config.yaml`                                    |
| `custom.regex` (annotated) | `config/versions.env`, and the k0s, flux-operator and Flux distribution pins |

The built-in managers are scoped to the directories they belong to, because a manager with no
file patterns walks the whole tree. SOPS files are excluded outright: their `version:` field
records the sops binary that encrypted them, which is history, not a dependency.

## The annotation convention

Renovate cannot guess the upstream of a bare shell variable or a Jinja-templated YAML value. Those
pins carry a comment on the line directly above:

```bash
# renovate: datasource=github-releases depName=terrastruct/d2
D2_VERSION=v0.7.1
```

`versioning=` and `extractVersion=` are both optional and go after `depName=`, in that order —
`kustomize` needs `extractVersion` because it tags releases `kustomize/v5.5.0`, and `k0s` needs
`versioning` because `v1.36.3+k0s.0` is not plain semver.

The comment must stay immediately above its pin. Insert a line between them, or move the pin
without its comment, and it silently stops being tracked — no error, just an update that never
arrives. `.github/workflows/validate.yml` validates the config itself on every pull request, but
nothing can validate an annotation that is simply absent.

Group rules exist for the pins that are one decision written twice: the `gitleaks` version in both
`config/versions.env` and `.pre-commit-config.yaml`, the Velero chart and its CLI, the
VictoriaMetrics stack, mdbook and its d2 preprocessor, the Flux operator and the distribution it
installs.

## What merges itself

GitHub Actions only, and only minor, patch and digest, after the release has been public for three
days and `validate.yml` has passed. An action bump cannot reach the cluster; everything else can,
so everything else waits for a human.

Two of those PRs deserve a closer read than the rest:

- **k0s** (`ansible/roles/k0s_cluster/defaults/main.yml`) is a control-plane upgrade. Merging it
  changes nothing on its own — it takes effect on the next `just ans k0s`, which drains and
  restarts each node in turn.
- **Chart majors** carry values-schema changes. `kustomize build --enable-helm` in CI renders the
  chart, so a values key that no longer exists fails the PR, but a key that changed meaning does
  not.

## Running it by hand

```bash
gh workflow run renovate.yml -f logLevel=debug -f dryRun=true
```

`dryRun` extracts and logs without creating branches, PRs or issues — the way to check that a new
annotation or file pattern is picked up. The log line to look for is `packageFiles with updates`,
which lists every dependency found per manager. A manager showing zero has a file pattern that no
longer matches.

Locally, without any token:

```bash
npx --yes --package renovate -- renovate --platform=local
```

## Repository prerequisites

Renovate authenticates as a GitHub App of ours, minted per run and expiring within the hour. The
default `GITHUB_TOKEN` cannot be used: pull requests it opens do not trigger `on: pull_request`,
so `validate.yml` would never run and nothing would gate an automerge.

The App needs read/write on contents, pull requests, issues and workflows, installed on this
repository, with its ID in the `RENOVATE_APP_ID` variable and its private key in the
`RENOVATE_APP_PRIVATE_KEY` secret.

Two settings outside the repo tree matter as much as the config:

- **Allow auto-merge** must be on, and `master` must require the `validate` checks. Without a
  required check, an auto-merge lands the moment the PR opens.
- **Labels must already exist.** Renovate applies `type/{major,minor,patch,digest}` and
  `renovate/{container,helm,terraform,ansible,github-action,tool}`; it does not create them, and
  a label it cannot find is dropped without an error. `just ops labels` creates or updates them,
  reading the names straight out of `packageRules` so the two cannot disagree — colour and
  description follow from the prefix. Run it once, and again after adding a label to the config.
  It never deletes, so anything you added by hand survives.
