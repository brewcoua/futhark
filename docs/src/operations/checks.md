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

Five workflows, all in `.github/workflows/`.

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

**`trivy.yml`** scans container images for known vulnerabilities on every pull request touching
`infra/`, `nodes/` or `flux/`, weekly on a cron, and on demand. It is described in
[Vulnerability scanning](#vulnerability-scanning) below.

**`renovate.yml`** runs Renovate at 03:00, on a change to its own config, and on demand. That is
an hour before the mirror cron, so an automerged update reaches Codeberg the same night. What it
covers and what it may merge is [Dependency updates](../conventions/updates.md).

**`mirror.yml`** pushes a full mirror to Codeberg on every push to `master`, daily on a cron, and
on demand. It is disaster recovery, not a second remote you push to. It uses `ssh-keyscan` for the
host key, which is trust-on-first-use, because Codeberg publishes no authenticated equivalent to
GitHub's `api.github.com/meta`. The blast radius is this mirror push only, not the live Flux
deploy-key channel.

All five workflows check out with `persist-credentials: false`, and every tool they install is
pinned in `mise.toml`, the same file `just ops deps` reads. A local `just docs build` therefore
renders with the mdbook CI publishes, and pre-commit runs the kustomize CI installs. Neither side
constructs a download URL: `validate.yml` and `docs.yml` run `jdx/mise-action`, `just ops deps`
runs `mise install`, and both get the same checksummed binaries.

**CI holds no decryption key and must never need one.** Nothing above decrypts: `kustomize build`
parses SOPS output fine, because SOPS encrypts values and leaves keys alone, and `sops-encrypted`
only greps. `ansible-playbook --syntax-check` parses playbooks without templating inventory
variables, so the `file` lookups in `group_vars/all/` are never evaluated and the missing
`ansible/.generated/` files do not fail it. Keep it that way rather than putting a key into GitHub
Actions.

## Vulnerability scanning

[Trivy](https://trivy.dev) runs in two places, answering two different questions.

### What a commit would run

`.github/workflows/trivy.yml` renders the manifests, collects every image reference, and scans
each one. It renders twice: `kustomize build` for what this repository writes, then
`helm template` per `HelmRelease` for what the charts bring with them, and it adds Flux's own
controllers, whose tags `flux/cluster.yaml` does not name directly. Findings land in this
repository's Security tab under Code scanning, one entry per image repository, and a pull request
gets a comment linking to its own results.

The entry is keyed on the repository rather than on the full reference so that it follows an image
across a tag bump: the next scan of that repository supersedes the previous one and closes what
the bump fixed. Keyed on the tag, the old findings would stay open under a name nothing scans
again.

Rendering rather than diffing is deliberate. A diff shows the one image a commit renamed, and the
question is what the cluster would then be running. Rendering is also the only view that reaches
the chart-internal images (Traefik, Grafana, cert-manager, K8up, VictoriaMetrics), which
[Version pins](../conventions/layout.md#version-pins) does not digest-pin and no commit here ever
names.

The scan never fails the check. A HIGH in an upstream base image is not something a pull request
against this repository can fix, and a check nobody can turn green is a check people learn to
click past.

To reproduce one image locally before opening a pull request:

```bash
just sec scan ghcr.io/open-webui/open-webui:v0.11.0
```

To scan an image the workflow does not discover, run it on demand:

```bash
gh workflow run trivy.yml -f image=docker.io/library/nginx:1.29
```

The run logs `discovered N images` before the matrix expands. A count that dropped without a
manifest change means a `helm template` call started failing, which the same log records as a
`::warning::` naming the file and chart.

### What the cluster is running now

`infra/trivy-operator` watches workloads and writes a report per image, plus config audits, RBAC
assessments, node hardening checks and CIS/NSA compliance. There is no web interface. The reports
are Kubernetes objects, and `just sec` reads them:

```bash
just sec           # the recipes in this module
just sec reports   # vulnerability counts per workload, worst first
just sec compliance
```

Start at `just sec reports`, then open the row that stands out. The report name is
`<kind>-<hash>`, which is why the recipe prints the workload name alongside it:

```bash
just sec show replicaset-open-webui-7d9c4f8b5 open-webui
```

Expect an empty list for the first few minutes after install, while the operator downloads its
vulnerability database. `kubectl -n trivy-system get jobs` shows the scans as they run, one at a
time.

This is not a duplicate of CI. A merged commit stops describing reality the moment a CVE is
published against an image that has not changed, and the operator is the only thing here that
notices.

To confirm a finding is gone after merging the bump, force the reports to be rebuilt rather than
waiting for the operator's own interval:

```bash
just sec rescan open-webui
```

Three alerts reach Slack, from `infra/monitoring/app/grafana/alerting/security.yaml`: a fixable
CRITICAL in any workload, a cluster-wide CRITICAL and HIGH count above its 24-hour floor, and a
compliance spec failing more controls than its 7-day baseline. The last two are regression alarms
rather than presence checks, because CIS fails controls on a single-node k3s that no change here
will satisfy, and an alert that is always firing gets muted. The Glance cluster page carries the
same counts as a widget.

### Suppressing a finding

`.trivyignore` at the repository root is the only place a suppression is written. All three
scanners read that one file: `.github/workflows/trivy.yml` passes it to the action, `just sec scan`
passes it to the CLI, and `infra/trivy-operator/app/kustomization.yaml` copies it into the
operator's HelmRelease values as it builds. The copy is a kustomize replacement rather than a
`valuesFrom` reference, because Flux resolves a `valuesFrom` key through Helm's `--set` parser,
which reads a comma in a comment as a value separator and fails the release.

An entry belongs there only when the scanner cannot decide the finding, such as an advisory it
cannot match against the installed version. A finding that is merely inconvenient does not qualify:
suppress it and the alerts in `infra/monitoring/app/grafana/alerting/security.yaml` go quiet
without anything being fixed. Give every entry a comment saying which image it covers and why the
scanner is wrong, because nothing else records it.

Write one ID per line. The chart's own `trivy.ignoreFile` list syntax is not used, and should not
be: it renders each ID as a YAML list item, which the scanner then reads as the literal `-`.

An edit reaches the cluster on the next Flux reconcile, but existing reports are not rebuilt for
it. Run `just sec rescan <namespace>` to see the effect.

### What neither scanner covers

Both run with `ignore-unfixed`, so a vulnerability with no published fix never reaches you. That
is the intent: it leaves nothing to merge. It also means every finding that does arrive
corresponds to a Renovate pull request worth
[merging out of schedule](../conventions/updates.md#merging-one-out-of-schedule).

Neither scanner reads this repository's own tree for misconfiguration. `gitleaks` and GitGuardian
cover secrets, and the operator's config-audit scanner covers workload hardening from the cluster
side, which is where the objects Helm generates are visible at all.

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

NetBird Personal Access Tokens expire, 365 days out at most. Three are in use, one on each of the
three service users:

| Token                | Referenced from           | Breaks when it expires                                     |
| -------------------- | ------------------------- | ---------------------------------------------------------- |
| `netbird-policy`     | `tofu.netbird`            | `just tf plan netbird` fails with a 401                    |
| `netbird-enrollment` | `ansible.secrets.netbird` | A node join fails at "Mint a single-use setup key"         |
| `netbird-readonly`   | Infisical `/infra/glance` | The NetBird peers widget on the Glance network page errors |

None takes the mesh down when it lapses. Peers keep their configuration and keep connecting.
What stops is changing anything: no policy applies, and no new node joins. The read-only one costs
one widget and nothing else.

Nothing in this repository tracks the expiry dates. Put them in a calendar when you issue the
tokens. The replacement procedure is
[Credential rotation](rotation.md#the-netbird-tokens).

## The forge node's own signals

`brokkr` is outside the cluster, so nothing above reaches it and it reports on itself. Both signals
are node-exporter textfile metrics, written by the units that produce them and scraped over the mesh:

| Metric                                  | Goes to 0 when                                                                   |
| --------------------------------------- | -------------------------------------------------------------------------------- |
| `futhark_quadlet_last_run_success`      | A reconcile failed: a non-fast-forwardable branch, or a unit that will not start |
| `futhark_forge_backup_last_run_success` | A backup failed: usually an expired B2 key or a full disk                        |

`futhark_quadlet_revision_info` carries the revision the node currently has applied, as a label,
which is the fastest way to answer "did that commit land". Read it with
`ssh brokkr git -C /var/lib/futhark-gitops rev-parse --short HEAD`, or from the metric.

Two Gatus endpoints cover it from the cluster side, `git.$DOMAIN` and `ci.$DOMAIN`, in a `Forge`
group of their own. The direction of dependency is deliberate: the cluster watches the fallback, so
you learn the fallback is gone before you need it. Their `[CERTIFICATE_EXPIRATION]` assertion does
more work than anywhere else on that page, because these two certificates are renewed by a Traefik
process on a machine nothing else watches, not by cert-manager. See
[The standalone Podman plane](../gitops/podman.md).

## What has no check at all

Worth stating, because the absence is easy to mistake for coverage:

- **NetBird policy.** There are no server-side policy tests, so a wrong rule applies cleanly and
  fails later, in traffic. The [isolating test](../ansible/networking.md#the-isolating-test) is
  the substitute.
- **The forge's Quadlet units.** `kustomize-build` never sees them, because they are systemd unit
  files rather than manifests and their directory holds no `kustomization.yaml`. Nothing validates
  them before they reach the node, so a broken unit is caught by the reconciler failing on the node,
  not by a hook. Recovery is another commit; see
  [Changing what runs](../gitops/podman.md#changing-what-runs).
- **The break-glass admin.** Nothing proves it still works, and it is the one credential whose whole
  purpose is being available during an outage. Test it deliberately, by logging in to `git.$DOMAIN`
  with Pocket ID scaled to zero.
- **Credential expiry.** Nothing watches it. See above.
- **Backups that copied nothing.** A malformed exclude annotation makes K8up skip that PVC and
  the job still succeeds. The size column in `just bak snapshots` is the check, and the 26h alert in
  `infra/monitoring/app/grafana/alerting/backup.yaml` is the backstop only for a namespace that
  stopped entirely. See [Backup and recovery](recovery.md).
