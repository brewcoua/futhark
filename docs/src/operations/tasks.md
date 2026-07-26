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

| Task              | Does                                                                 |
| ----------------- | -------------------------------------------------------------------- |
| `ops:setup`       | Everything below, plus `tf:init`. Run this once on a new workstation |
| `ops:deps`        | Install the toolchain. Needs `dnf` and `uv`                          |
| `ops:collections` | `ansible-galaxy collection install -r requirements.yml`              |
| `ops:hooks`       | `pre-commit install`                                                 |

## `ans:` — hosts

| Task                    | Does                                     |
| ----------------------- | ---------------------------------------- |
| `ans:setup [-- <host>]` | First contact and hardening. Re-runnable |
| `ans:k0s`               | Converge the cluster and bootstrap Flux  |
| `ans:ping`              | `ansible all -m ping`                    |
| `ans:lint`              | `ansible-lint`                           |

## `bao:` — OpenBao

| Task               | Does                                                                |
| ------------------ | ------------------------------------------------------------------- |
| `bao:status`       | Seal and init status                                                |
| `bao:policy-sync`  | Namespace, mount, auth and policy bootstrap. Idempotent             |
| `bao:kv -- <args>` | Run `bao kv` in-cluster. Root token is piped over stdin, never argv |

```bash
task bao:kv -- get -namespace=node-kenaz secret/actual
task bao:kv -- put -namespace=infra secret/foo key=value
```

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

Every `k0s:*` and `fx:*` task points `KUBECONFIG` at `ansible/.generated/kubeconfig` itself —
you do not need it in your environment.

## `tf:` — the cloud plane

| Task                      | Does                                                 |
| ------------------------- | ---------------------------------------------------- |
| `tf:init [-- <module>]`   | All modules if no argument. No secrets needed        |
| `tf:plan -- <module>`     | Plan, with `secrets.env` resolved through `pass-cli` |
| `tf:apply -- <module>`    | Apply                                                |
| `tf:validate -- <module>` | `tofu validate`                                      |

## `docs:` — this book

| Task         | Does                                         |
| ------------ | -------------------------------------------- |
| `docs:build` | Build into `docs/book/`, which is gitignored |
| `docs:serve` | Serve with live reload and open a browser    |
