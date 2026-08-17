# Dependency updates

How pinned versions get bumped, what Renovate can and cannot see, and what you must do by hand for
a new pin to be tracked at all.

Every version in this repository is pinned exactly ([Version pins](layout.md#version-pins)), which
is only sustainable if something else does the watching. Renovate reads the whole tree once a night
and opens a pull request per update. The [Dependency Dashboard][dash] issue lists everything it
knows about, including updates it has not opened a PR for yet.

[dash]: https://docs.renovatebot.com/key-concepts/dashboard/

Config lives in `.github/renovate.json5`, and it runs from `.github/workflows/renovate.yml`. This
is a self-hosted Renovate, not the Mend-hosted GitHub App, so no third party holds write access to
the repository.

## What it covers

| Manager                    | Reaches                                                           |
| -------------------------- | ----------------------------------------------------------------- |
| `flux`                     | `HelmRelease` chart versions and the images inside their `values` |
| `kubernetes`               | Images in plain manifests under `infra/` and `nodes/`             |
| `terraform`                | `tofu/*/provider.tf` constraints and `.terraform.lock.hcl`        |
| `ansible-galaxy`           | `ansible/requirements.yml`                                        |
| `github-actions`           | Action pins in every workflow                                     |
| `pre-commit`               | Hook `rev:`s in `.pre-commit-config.yaml`                         |
| `mise`                     | The pinned tool binaries in `mise.toml`                           |
| `custom.regex` (annotated) | The k3s, flux-operator and Flux distribution pins                 |
| `custom.regex` (Quadlet)   | `Image=` pins in `nodes/*.podman/units/*.container`               |

The built-in managers are scoped to the directories they belong to, because a manager with no
file patterns walks the whole tree. SOPS files are excluded outright: their `version:` field
records the sops binary that encrypted them, which is history, not a dependency.

## The annotation convention

Renovate cannot guess the upstream of a YAML value no built-in manager understands. Those pins
carry a comment on the line directly above:

```yaml
# renovate: datasource=github-releases depName=fluxcd/flux2 extractVersion=^v(?<version>.+)$
version: "2.9.4"
```

`versioning=` and `extractVersion=` are both optional and go after `depName=`, in that order.
`k3s` needs `versioning` because `v1.36.3+k3s1` is not plain semver.

The comment must stay immediately above its pin. Insert a line between them, or move the pin
without its comment, and it silently stops being tracked. There is no error, just an update that
never arrives. `.github/workflows/validate.yml` validates the config itself on every pull request, but
nothing can validate an annotation that is simply absent.

The Quadlet manager needs no annotation, because a `.container` file's `Image=` key is already an
unambiguous shape: `Image=<repo>:<tag>@sha256:<digest>`, the same `tag@digest` pin every manifest in
this repository uses. It exists at all because no built-in manager reads a systemd unit file, so
without it those four images would never move and "nothing floats" would quietly become "nothing
moves". Those pins reach a node outside the cluster; how they get applied is
[The standalone Podman plane](../gitops/podman.md).

Group rules exist for the pins that are one decision written twice: the `gitleaks` version in both
`mise.toml` and `.pre-commit-config.yaml`, the VictoriaMetrics stack, mdbook and its d2
preprocessor, the Flux operator and the distribution it installs.

## What merges itself

GitHub Actions only, and only minor, patch and digest, after the release has been public for three
days and `validate.yml` has passed. An action bump cannot reach the cluster. Everything else can,
so everything else waits for a human.

Two of those PRs deserve a closer read than the rest:

- **k3s** (`ansible/roles/k8s_cluster/defaults/main.yml`) is a control-plane upgrade. Merging it
  changes nothing on its own. It takes effect on the next `just ans k8s`, which drains and
  restarts each node in turn.
- **Chart majors** carry values-schema changes. `kustomize build --enable-helm` in CI renders the
  chart, so a values key that no longer exists fails the PR, but a key that changed meaning does
  not.

## Merging one out of schedule

Renovate decides when an update is available. Trivy decides when one is urgent.

A Slack alert for a fixable CRITICAL, or a finding in the Security tab, names an image that has a
published fix. Both scanners run with `ignore-unfixed`, so nothing else reaches you. The
corresponding pull request is already open on the [Dependency Dashboard][dash]. Merge that one
rather than waiting for the next pass over the list.

Chart-internal images have no pull request of their own. Bump the chart version instead, which is
the only pin this repository holds for them, and confirm the new one carries the fix:

```bash
just sec scan docker.io/traefik:v3.7.9
```

[Vulnerability scanning](../operations/checks.md#vulnerability-scanning) covers what each scanner
sees.

## Running it by hand

```bash
gh workflow run renovate.yml -f logLevel=debug -f dryRun=true
```

`dryRun` extracts and logs without creating branches, PRs or issues, which is how to check that a
new annotation or file pattern is picked up. The log line to look for is `packageFiles with
updates`, which lists every dependency found per manager. A manager showing zero has a file
pattern that no longer matches.

Locally, without any token:

```bash
npx --yes --package renovate -- renovate --platform=local
```

## Repository prerequisites

Renovate authenticates as a GitHub App of ours, minted per run and expiring within the hour. The
default `GITHUB_TOKEN` cannot be used: pull requests it opens do not trigger
`on: pull_request`, so `validate.yml` would never run and nothing would gate an automerge.

The App needs read/write on contents, pull requests, issues and workflows, installed on this
repository, with its ID in the `RENOVATE_APP_ID` variable and its private key in the
`RENOVATE_APP_PRIVATE_KEY` secret.

Its commits are signed by GitHub, not by a key of ours. `platformCommit` makes Renovate write
through the GitHub API instead of `git push`, and GitHub signs what it writes with the App's
identity. A key we held would have to live in a repository secret and could not be verified
anyway: a GitHub App has no user account to register a public key against, so the signature would
show as unverified.

Three settings outside the repo tree matter as much as the config:

- **Allow auto-merge** must be on, and `master` must require the `validate` checks. Without a
  required check, an auto-merge lands the moment the PR opens.
- **Allow squash merging** must be on, and `master` must require signed commits. `platformCommit`
  signs what Renovate pushes; `automergeStrategy: "squash"` makes GitHub author and sign the
  commit that lands, where a rebase merge would replay the branch commits and drop their
  signatures. Enable the signed-commit rule only after a run has confirmed the branch commits are
  signed, or Renovate's pushes are rejected and every pull request stalls. Afterwards, rebasing a
  bot branch locally and pushing it is refused unless you re-sign the rewritten commits.
- **Labels must already exist.** Renovate applies `type/{major,minor,patch,digest}` and
  `renovate/{container,helm,terraform,ansible,github-action,tool}`; it does not create them, and
  a label it cannot find is dropped without an error. `just ops labels` creates or updates them,
  reading the names straight out of `packageRules` so the two cannot disagree. Colour and
  description follow from the prefix. Run it once, and again after adding a label to the config.
  It never deletes, so anything you added by hand survives.
