# Task reference

Everything an operator runs goes through [go-task](https://taskfile.dev). The root
`Taskfile.yaml` is only a set of includes; the real definitions are one file per namespace
under `.taskfiles/`.

```bash
task --list
```

Arguments come after `--`. A task documented as `-- <x>` requires one; `[-- <x>]` takes an
optional one.

## `ops:` — the operator machine

| Task                   | Does                                                                                                      |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| `ops:setup`            | Everything below, plus `tf:init`. Run this once on a new workstation                                      |
| `ops:deps`             | Install the toolchain. Needs `dnf` and `uv`                                                               |
| `ops:collections`      | `ansible-galaxy collection install -r requirements.yml`                                                   |
| `ops:hooks`            | `pre-commit install`                                                                                      |
| `ops:age-key`          | Generate the SOPS cluster age keypair. Run once, at cold bootstrap                                        |
| `ops:sops [-- <file>]` | Edit an encrypted file, seeding it from its `.example` if absent. No argument lists what is still missing |

`ops:age-key` is not part of `ops:setup`: it mints key material, so it is deliberately explicit.
It prints the public recipient for `.sops.yaml` and leaves the private key in a temporary file
for you to store in Proton Pass and shred.

`ops:sops` takes either name — `foo.sops.yaml` or `foo.sops.yaml.example` — and always edits the
real file. If it does not exist yet, the template is copied, opened, and encrypted on save. It
fails closed: an aborted edit or a failed encrypt deletes the plaintext rather than leaving it at
a `*.sops.*` path.

```bash
task ops:sops                                    # what is still missing
task ops:sops -- tofu/bunny/secrets.sops.env     # create it, or edit it
```

## `ans:` — hosts

| Task                    | Does                                     |
| ----------------------- | ---------------------------------------- |
| `ans:setup [-- <host>]` | First contact and hardening. Re-runnable |
| `ans:k0s`               | Converge the cluster and bootstrap Flux  |
| `ans:ping`              | `ansible all -m ping`                    |
| `ans:lint`              | `ansible-lint`                           |

## `fx:` — Flux

| Task                        | Does                                                            |
| --------------------------- | --------------------------------------------------------------- |
| `fx:get`                    | Kustomizations and their sync status                            |
| `fx:sources`                | GitRepository sources                                           |
| `fx:hr`                     | HelmReleases                                                    |
| `fx:failing`                | Only Kustomizations and HelmReleases that aren't Ready          |
| `fx:reconcile [-- <name>]`  | Force-reconcile one, or all of them, `--with-source`            |
| `fx:redeploy -- <name>`     | Force a HelmRelease to reinstall even if its chart is unchanged |
| `fx:logs [-- <controller>]` | Tail a controller, default `kustomize-controller`               |

## `k0s:` — the cluster

| Task                           | Does                                                                      |
| ------------------------------ | ------------------------------------------------------------------------- |
| `k0s:status`                   | One screen: nodes, unhealthy pods, Flux sync state                        |
| `k0s:nodes`                    | `kubectl get nodes -o wide`                                               |
| `k0s:pods [-- <ns>]`           | List pods                                                                 |
| `k0s:failing`                  | Only pods not Running with every container ready. Completed Jobs excluded |
| `k0s:events [-- <ns>]`         | Recent events, oldest first                                               |
| `k0s:warnings [-- <ns>]`       | Warning events only                                                       |
| `k0s:logs -- <ns>/<name>`      | Follow logs. `<name>` may be `deploy/x`, `job/x`, or a pod                |
| `k0s:previous -- <ns>/<pod>`   | A crashed pod's logs from before its last restart                         |
| `k0s:describe -- <ns>/<pod>`   | Describe a pod, with its events                                           |
| `k0s:restart -- <ns>/<deploy>` | Roll a Deployment and wait for it                                         |
| `k0s:jobs [-- <ns>]`           | Jobs and CronJobs                                                         |
| `k0s:jobs-clean [-- <ns>]`     | Delete finished Jobs. Running ones are left alone                         |
| `k0s:top`                      | Real CPU/memory per node, and the 15 hungriest pods                       |
| `k0s:ingress`                  | Ingresses across all namespaces                                           |
| `k0s:certs`                    | Certificates and pending CertificateRequests                              |
| `k0s:apply`                    | Re-converge with k0sctl and re-bootstrap Flux                             |

Every `k0s:*`, `fx:*` and `bak:*` task points `KUBECONFIG` at `ansible/.generated/kubeconfig`
itself — you do not need it in your environment.

## `bak:` — backups

| Task                             | Does                                                          |
| -------------------------------- | ------------------------------------------------------------- |
| `bak:backups`                    | Every backup and its status                                   |
| `bak:schedules`                  | Schedules, and when each last ran                             |
| `bak:describe -- <backup>`       | What a backup contains, including which volumes it copied     |
| `bak:logs -- <backup>`           | A backup's log                                                |
| `bak:now`                        | Run the daily schedule immediately                            |
| `bak:restore -- <ns>[/<backup>]` | **Wipes** the namespace's `local-path` PVCs and restores them |

`bak:restore` deletes data. It prints which PVCs it will destroy and which it will leave alone —
`storagebox-crypt` volumes are never touched — and requires you to type the namespace back before
it proceeds. It is deliberately not reachable from any other task.
[Backup and recovery](recovery.md) covers what it does behind that prompt, and why a hand-run
`velero restore` is not equivalent.

## `tf:` — the cloud plane

| Task                      | Does                                                         |
| ------------------------- | ------------------------------------------------------------ |
| `tf:init [-- <module>]`   | All modules if no argument. No secrets needed                |
| `tf:plan -- <module>`     | Plan, through `sops exec-env` and `pass-cli run` — see below |
| `tf:apply -- <module>`    | Apply                                                        |
| `tf:validate -- <module>` | `tofu validate`                                              |

`plan` and `apply` need a Proton Pass session and the GPG smartcard plugged in. There is no
editing secrets from here — secret values live in Proton Pass, and each module's
`secrets.sops.env` holds only identifying values and the `pass://` references that point at
them. Edit it with `sops`.

## `docs:` — this book

| Task         | Does                                         |
| ------------ | -------------------------------------------- |
| `docs:build` | Build into `docs/book/`, which is gitignored |
| `docs:serve` | Serve with live reload and open a browser    |
