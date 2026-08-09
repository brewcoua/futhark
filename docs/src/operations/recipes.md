# Recipe reference

Every recipe in this repository, what it does, and which ones need a credential. Use it to find
the command; the pages linked from each section explain the procedure around it.

Everything an operator runs goes through [just](https://just.systems). The root `justfile` is only
a set of `mod` declarations. The real definitions are one file per namespace under `.just/`.

```bash
just --list        # the namespaces
just --list ks     # one namespace's recipes
```

Arguments are positional: `just ks logs media sonarr`. A recipe documented as `<x>` requires that
argument, and `[<x>]` takes an optional one.

## `ops`, the operator machine

| Recipe              | Does                                                                                                      |
| ------------------- | --------------------------------------------------------------------------------------------------------- |
| `ops setup`         | Everything below, plus `tf init`. Run this once on a new workstation                                      |
| `ops deps`          | Install the toolchain. Needs `dnf` and `uv`                                                               |
| `ops collections`   | `ansible-galaxy collection install -r requirements.yml`                                                   |
| `ops hooks`         | `pre-commit install`                                                                                      |
| `ops labels`        | Create or update the GitHub labels Renovate applies to its PRs. Needs `gh`                                |
| `ops age-key`       | Generate the SOPS cluster age keypair. Run once, at cold bootstrap                                        |
| `ops sops [<file>]` | Edit an encrypted file, seeding it from its `.example` if absent. No argument lists what is still missing |
| `ops pass-session`  | Check for a Proton Pass session, and explain how to get one                                               |
| `ops mesh`          | Check this machine is on the NetBird mesh, and explain how to join if not                                 |

`just` itself is the one thing `ops deps` cannot install for you. It has to be there to run the
recipe. `sudo dnf install just` first.

The `tf init` inside `ops setup` skips any module with a `backend.tf` while
`config/sops/ops.sops.yaml` does not exist yet, and says so. That is the cold-bootstrap case: setup
runs at step 3, the encrypted files land at step 5. Run `just tf init <module>` for it afterwards.

`ops mesh` only reports: `netbird up` is an interactive SSO login, and the `admin` group it has
to land in is filled from the dashboard, not from `tofu/netbird`. `ops deps` installs the client
either way.

`ops age-key` is not part of `ops setup`: it mints key material, so it is deliberately explicit.
It prints the public recipient for `.sops.yaml` and leaves the private key in a temporary file
for you to store in Proton Pass and shred.

`ops sops` takes either name, `foo.sops.yaml` or `foo.sops.yaml.example`, and always edits the
real file. If it does not exist yet, the template is copied, opened, and encrypted on save. It
fails closed: an aborted edit or a failed encrypt deletes the plaintext rather than leaving it at
a `*.sops.*` path.

```bash
just ops sops                                 # what is still missing
just ops sops config/sops/ops.sops.yaml           # create it, or edit it
```

## `ans`, hosts

| Recipe               | Does                                                           |
| -------------------- | -------------------------------------------------------------- |
| `ans setup [<host>]` | First contact and hardening. Re-runnable                       |
| `ans k0s`            | Converge the cluster and bootstrap Flux                        |
| `ans render-secrets` | Resolve the crown jewels into `ansible/.generated/secrets.yml` |
| `ans ping`           | `ansible all -m ping`                                          |
| `ans lint`           | `ansible-lint`                                                 |

`setup` and `k0s` both depend on `render-secrets`, so you rarely run it by hand.

## `fx`, Flux

| Recipe                   | Does                                                            |
| ------------------------ | --------------------------------------------------------------- |
| `fx get`                 | Kustomizations and their sync status                            |
| `fx sources`             | GitRepository sources                                           |
| `fx hr`                  | HelmReleases                                                    |
| `fx failing`             | Only Kustomizations and HelmReleases that aren't Ready          |
| `fx reconcile [<name>]`  | Force-reconcile one, or all of them, `--with-source`            |
| `fx redeploy <name>`     | Force a HelmRelease to reinstall even if its chart is unchanged |
| `fx logs [<controller>]` | Tail a controller, default `kustomize-controller`               |

## `ks`, the cluster

| Recipe                     | Does                                                                      |
| -------------------------- | ------------------------------------------------------------------------- |
| `ks status`                | One screen: nodes, unhealthy pods, Flux sync state                        |
| `ks nodes`                 | `kubectl get nodes -o wide`                                               |
| `ks pods [<ns>]`           | List pods                                                                 |
| `ks failing`               | Only pods not Running with every container ready. Completed Jobs excluded |
| `ks events [<ns>]`         | Recent events, oldest first                                               |
| `ks warnings [<ns>]`       | Warning events only                                                       |
| `ks logs <ns> <name>`      | Follow logs. `<name>` may be `deploy/x`, `job/x`, or a pod                |
| `ks previous <ns> <pod>`   | A crashed pod's logs from before its last restart                         |
| `ks describe <ns> <pod>`   | Describe a pod, with its events                                           |
| `ks restart <ns> <deploy>` | Roll a Deployment and wait for it                                         |
| `ks jobs [<ns>]`           | Jobs and CronJobs                                                         |
| `ks jobs-clean [<ns>]`     | Delete finished Jobs. Running ones are left alone                         |
| `ks top`                   | Real CPU/memory per node, and the 15 hungriest pods                       |
| `ks ingress`               | Ingresses across all namespaces                                           |
| `ks certs`                 | Certificates and pending CertificateRequests                              |
| `ks kctl <args>`           | `kubectl` passthrough, using the generated kubeconfig                     |

Every `ks`, `fx` and `bak` recipe points `KUBECONFIG` at `ansible/.generated/kubeconfig` itself,
so you do not need it in your environment. Re-converging the cluster is `just ans k0s`.

## `bak`, backups

| Recipe                        | Does                                                          |
| ----------------------------- | ------------------------------------------------------------- |
| `bak backups`                 | Every backup and its status                                   |
| `bak restores`                | Every restore and its status                                  |
| `bak schedules`               | Schedules, and when each last ran                             |
| `bak describe <backup>`       | What a backup contains, including which volumes it copied     |
| `bak logs <backup>`           | A backup's log                                                |
| `bak now`                     | Run the daily schedule immediately                            |
| `bak restore <ns> [<backup>]` | **Wipes** the namespace's `local-path` PVCs and restores them |

`bak restore` deletes data. It prints which PVCs it will destroy and which it will leave alone,
and requires you to type the namespace back before it proceeds. Only `local-path` PVCs are ever
wiped, so the rclone-backed classes are never touched. It is deliberately not reachable from any other recipe. The backup defaults to the
newest completed one. [Backup and recovery](recovery.md) covers what it does behind that prompt,
and why a hand-run `velero restore` is not equivalent.

## `tf`, the cloud plane

| Recipe                             | Does                                                                    |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `tf init [<module>]`               | All modules if no argument. No secrets, unless the module has a backend |
| `tf plan <module>`                 | Plan, through `sops --extract` and `pass-cli run`, see below            |
| `tf apply <module>`                | Apply                                                                   |
| `tf adopt <module> <address> <id>` | `tofu import`, taking over a resource that exists at the provider       |
| `tf validate <module>`             | `tofu validate`                                                         |

`plan`, `apply` and `adopt` need a Proton Pass session and the GPG smartcard plugged in, and so
does `init` for a module that ships a `backend.tf`, because initialising a remote backend
authenticates against it. There is no editing secrets from here. Secret values live in Proton Pass, and each module's
`tofu.<module>` section of `config/sops/ops.sops.yaml` holds only identifying values and the `pass://`
references that point at them. Edit it with `just ops sops`.

## `docs`, this book

| Recipe       | Does                                         |
| ------------ | -------------------------------------------- |
| `docs build` | Build into `docs/book/`, which is gitignored |
| `docs serve` | Serve with live reload and open a browser    |
