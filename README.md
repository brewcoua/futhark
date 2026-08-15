[![validate](https://github.com/brewcoua/futhark/actions/workflows/validate.yml/badge.svg)](https://github.com/brewcoua/futhark/actions/workflows/validate.yml)
[![trivy](https://github.com/brewcoua/futhark/actions/workflows/trivy.yml/badge.svg)](https://github.com/brewcoua/futhark/actions/workflows/trivy.yml)
[![docs](https://github.com/brewcoua/futhark/actions/workflows/docs.yml/badge.svg)](https://github.com/brewcoua/futhark/actions/workflows/docs.yml)
[![Codeberg Mirror](https://img.shields.io/badge/Mirror-Codeberg-blue?logo=codeberg)](https://codeberg.org/brewcoua/futhark)
[![License](https://img.shields.io/badge/License-Apache--2.0%20OR%20MIT-blue)](#license)

# futhark

The code for my GitOps-driven homelab: [Ansible](https://www.ansible.com/) provisions the hosts,
[Flux](https://fluxcd.io/) reconciles a [k3s](https://k3s.io/) cluster from this repository, and
[OpenTofu](https://opentofu.org/) manages what lives outside it.

**Documentation: <https://brewcoua.github.io/futhark/>** with source in [`docs/`](docs/).

| OS                                                                                              | Cluster                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Networking                                                                                                                                                                      | Cloud                                                                                                                                                                                                                                                                                                                                                                                                 | Tooling                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [![Fedora](https://img.shields.io/badge/-Fedora-black?logo=fedora)](https://fedoraproject.org/) | [![k3s](https://img.shields.io/badge/-k3s-black?logo=k3s)](https://k3s.io/) [![Flux](https://img.shields.io/badge/-Flux-black?logo=flux)](https://fluxcd.io/) [![cert-manager](https://img.shields.io/badge/-cert--manager-black?logo=letsencrypt)](https://cert-manager.io/) [![VictoriaMetrics](https://img.shields.io/badge/-VictoriaMetrics-black?logo=victoriametrics)](https://victoriametrics.com/) [![Grafana](https://img.shields.io/badge/-Grafana-black?logo=grafana)](https://grafana.com/) | [![NetBird](https://img.shields.io/badge/-NetBird-black)](https://netbird.io/) [![Traefik](https://img.shields.io/badge/-Traefik-black?logo=traefikproxy)](https://traefik.io/) | [![Bunny](https://img.shields.io/badge/-Bunny-black)](https://bunny.net/) [![Backblaze B2](https://img.shields.io/badge/-Backblaze%20B2-black?logo=backblaze)](https://www.backblaze.com/cloud-storage) [![Infisical](https://img.shields.io/badge/-Infisical-black)](https://infisical.com/) [![Proton Pass](https://img.shields.io/badge/-Proton%20Pass-black?logo=proton)](https://proton.me/pass) | [![Ansible](https://img.shields.io/badge/-Ansible-black?logo=ansible)](https://www.ansible.com/) [![OpenTofu](https://img.shields.io/badge/-OpenTofu-black?logo=opentofu)](https://opentofu.org/) [![just](https://img.shields.io/badge/-just-black)](https://just.systems) [![mise](https://img.shields.io/badge/-mise-black)](https://mise.jdx.dev/) [![Renovate](https://img.shields.io/badge/-Renovate-black?logo=renovate)](https://github.com/renovatebot/renovate) [![Trivy](https://img.shields.io/badge/-Trivy-black?logo=trivy)](https://trivy.dev) [![Actions](https://img.shields.io/badge/-Actions-black?logo=githubactions)](https://github.com/features/actions) |

## Overview

Two [Fedora](https://fedoraproject.org/) nodes joined over a [NetBird](https://netbird.io/) mesh
run one k3s cluster. `kenaz` runs the k3s server and carries my apps. `ogma` is an agent and the
cluster's only public entrypoint, so both Traefiks and Pocket ID are pinned to it with a
`nodeSelector`. Neither node is ever addressed by an address I store somewhere; they talk over
their mesh DNS names.

The tree splits along three planes, and almost every question I have about this repository
resolves to "which plane owns this?":

| Plane   | Owns                                                                       | Tool     | Where                       |
| ------- | -------------------------------------------------------------------------- | -------- | --------------------------- |
| Host    | The machines: users, SSH, firewall, mesh join, the k3s install itself      | Ansible  | `ansible/`                  |
| Cluster | Everything reconcilable from git: controllers, apps, namespaces, policy    | Flux     | `flux/`, `infra/`, `nodes/` |
| Cloud   | Provider APIs no Kustomization can express: DNS, OIDC clients, mesh policy | OpenTofu | `tofu/`                     |

Each plane hands off to the next exactly once, and nothing reaches back the other way. Ansible
installs k3s and bootstraps Flux, then stops touching the cluster. After that Flux is the only
writer, running as a [FluxInstance](https://fluxcd.control-plane.io/) that reconciles this
repository over SSH. The full picture is in the
[documentation index](docs/src/index.md).

I wanted the whole thing to be rebuildable from a cold start, so the bootstrap is written down as
twelve re-runnable steps in [Cold bootstrap](docs/src/operations/setup.md) rather than living in
my head.

## What runs

Cluster infrastructure lives in [`infra/`](infra/), one directory per component, and comes up
roughly in this order:

- The [Infisical](https://infisical.com/) operator, which pulls per-app runtime secrets into
  Kubernetes Secrets.
- [Pocket ID](https://pocket-id.org/) as the OIDC provider, with
  [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) behind a Traefik forward-auth
  middleware, so anything without its own login still gets one.
- [cert-manager](https://cert-manager.io/) with a single `letsencrypt-bunny` ClusterIssuer, solving
  [Let's Encrypt](https://letsencrypt.org/) DNS-01 through [Bunny](https://bunny.net/).
- Two [Traefiks](https://traefik.io/): `traefik-edge` on the public IngressClass `edge`, and
  `traefik-internal` on `internal`, reachable only over the mesh. Most things only need the second
  one.
- Storage: the k3s `local-path` class for anything that should stay on the node, plus
  [csi-driver-rclone](https://github.com/veloxpack/csi-driver-rclone) for the encrypted
  [rclone](https://rclone.org/) remotes.
- [K8up](https://k8up.io/) writing [restic](https://restic.net/) snapshots to
  [Backblaze B2](https://www.backblaze.com/cloud-storage).
- [VictoriaMetrics](https://victoriametrics.com/),
  [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) and
  [Grafana](https://grafana.com/), with [Gatus](https://gatus.io/) for uptime and
  [Glance](https://github.com/glanceapp/glance) as the homepage.
- [trivy-operator](https://aquasecurity.github.io/trivy-operator/), scanning what is already
  running.

My own apps live in [`nodes/`](nodes/), one directory per node, so a node's workload is obvious
from the tree. [Cluster infrastructure](docs/src/gitops/infra.md) and
[Node apps](docs/src/gitops/nodes.md) go through both.

One rule covers versions everywhere: nothing floats. Images pin `tag@sha256:...`, charts pin an
exact `MAJOR.MINOR.PATCH`, and every bump arrives as a
[Renovate](https://github.com/renovatebot/renovate) pull request I can read before it lands.
Renovate is self-hosted from [`.github/workflows/renovate.yml`](.github/workflows/renovate.yml)
rather than the Mend-hosted app, so no third party holds write access here.

## Security and networking

No credential is ever committed in the clear, and neither is any identifying value, because this
repository is public. Three stores split the work by what a value can _do_ rather than by who
consumes it:

- [**SOPS**](https://github.com/getsops/sops) for values that identify but grant nothing, such as
  node addresses and the domain. Encrypted in-repo, read by Ansible, OpenTofu and Flux.
- [**Proton Pass**](https://proton.me/pass) for anything that could bootstrap or re-key the system.
  Never committed, and the cluster holds no Proton Pass credential at all, so a cluster compromise
  cannot reach the keys that rebuild it. That boundary rests on absence rather than on a
  console-side grant I could misconfigure.
- [**Infisical**](https://infisical.com/) for per-app runtime secrets, reaching pods through the
  Infisical operator.

[Secrets](docs/src/conventions/secrets.md) documents the boundary and the checklist for adding one.

Every namespace starts default-deny. Traffic is opened back up by composing explicit bridges from
the templates in `infra/policies/namespaces/_templates/`, one directory per namespace, so nothing
talks to anything by accident. Namespaces also carry `futk.eu/tier` and `futk.eu/node` labels, and
those labels are load-bearing rather than decorative: a `ValidatingAdmissionPolicy` reads them to
decide which Infisical path a namespace may pull from. See
[Network policy](docs/src/conventions/network-policy.md).

Every container image is scanned by [Trivy](https://trivy.dev): before a merge in CI, with the
findings published to this repository's Security tab, and continuously in the cluster by
trivy-operator. Both halves share the same [`.trivyignore`](.trivyignore), so an exception I write
once holds in both places. `just sec reports` ranks what is live, and `just sec scan <image>` lets
me check a pin before committing it.

[gitleaks](https://github.com/gitleaks/gitleaks) runs twice, once as a
[pre-commit](https://pre-commit.com/) hook and again over the whole tree in CI, and
[GitGuardian](https://www.gitguardian.com/) watches the repository for anything that slips past it.
On the hosts, Ansible applies `ssh_harden`, [`fail2ban`](https://www.fail2ban.org/), `firewalld`
and `firewall_ingress`.

## Monitoring

I run a small stack rather than a complete one, on the theory that I will only act on what I
actually look at:

- **Metrics**: VictoriaMetrics single, scraped by vmagent, with kube-state-metrics, node-exporter
  and a custom egress exporter deployed by Ansible.
- **Logs**: VictoriaLogs single, fed by [Fluent Bit](https://fluentbit.io/).
- **Dashboards and alerts**: Grafana, logging in through Pocket ID. Dashboards and unified alerting
  rules are committed as JSON under [`infra/monitoring/`](infra/monitoring/), so a dashboard I
  break is a revert away.
- **Uptime**: Gatus.
- **Homepage**: Glance, pulling Flux state, mesh peers, backups, certificates and vulnerabilities
  into one page.

Sizing for the whole stack is centralised in [`infra/substitutions/`](infra/substitutions/) and
substituted in by Flux, so retention and limits move in one file instead of ten.

## Cloud dependencies

I self-host what I reasonably can. What is left:

| Provider                                                | Use                                                                 | Cost                           |
| ------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------ |
| [Bunny](https://bunny.net/)                             | DNS, and the cert-manager webhook that answers the DNS-01 challenge | $1/mo                          |
| [Backblaze B2](https://www.backblaze.com/cloud-storage) | Restic backup target, and the OpenTofu state backend                | $6.95/TB/mo                    |
| [NetBird](https://netbird.io/)                          | The mesh the nodes join and are addressed on                        | Free                           |
| [Infisical](https://infisical.com/)                     | Per-app runtime secrets, on the EU cloud                            | Free                           |
| [Proton Pass](https://proton.me/pass)                   | Bootstrap and re-key credentials, on operator machines only         | ~$120/y                        |
| [Let's Encrypt](https://letsencrypt.org/)               | Certificates                                                        | Free                           |
| [GitHub](https://github.com/)                           | This repository, CI, Pages, and self-hosted Renovate                | Free                           |
| [Codeberg](https://codeberg.org/brewcoua/futhark)       | Disaster-recovery mirror, pushed nightly                            | Free                           |
|                                                         |                                                                     | Total: ~$11/mo plus B2 storage |

## Getting started

This is not a template to clone. It is a working homelab with node names, a domain and a key
hierarchy baked into it, and it will not come up as-is for anyone else. Read it for how the pieces
fit rather than to run it. If a piece is useful, take that piece.

Everything I run goes through [`just`](https://just.systems):

```bash
just help
```

Recipes are grouped into eight modules, each with its own `just <module> help`:

| Module | What it drives                                                          |
| ------ | ----------------------------------------------------------------------- |
| `ops`  | The operator machine: dependencies, hooks, SOPS keys, Proton Pass, mesh |
| `ans`  | Ansible playbooks: host setup, the k3s cluster, rendered secrets        |
| `tf`   | OpenTofu modules: `init`, `plan`, `apply`, `adopt`, `validate`          |
| `fx`   | Flux: sync state, HelmReleases, reconciles, controller logs             |
| `ks`   | The cluster: health, pods, logs, events, certificates, usage            |
| `bak`  | K8up: schedules, snapshots, on-demand backups, restores                 |
| `sec`  | trivy-operator: vulnerability, config, RBAC and compliance reports      |
| `docs` | This documentation: build and serve                                     |

The toolchain is pinned in [`mise.toml`](mise.toml) and installed by `just ops setup`, so a second
operator machine matches this one exactly. The documentation is an
[mdBook](https://rust-lang.github.io/mdBook/) with [D2](https://d2lang.com/) diagrams, built and
published by CI on every push to `master`.

## License

This project is licensed under either of the following, at your option:

- Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT License ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in this project by you,
as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
