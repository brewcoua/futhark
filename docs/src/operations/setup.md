# Cold bootstrap

Build the whole thing from nothing, in order. At the end you have provisioned hosts on a NetBird
mesh, a k3s cluster reconciling from this repository through Flux, every runtime secret resolving
from Infisical, nightly backups reaching Backblaze B2, and optionally a git forge on a node outside
that cluster.

Every step is re-runnable. Expect a few hours, most of it waiting on reconciliation and on DNS-01
propagation.

## Prerequisites

Before step 1, have:

- A GPG key whose encryption subkey is on a smartcard, and the card. It is the only thing that
  opens the encrypted files in this repository.
- Accounts you will create along the way: Proton Pass, Infisical (EU region), NetBird Cloud,
  Backblaze B2, Bunny, and a GCP project if you want the Google Drive storage class.
- One or more hosts you can reach over SSH as root or as a sudo-capable user.
- Fedora or another `dnf` distribution on the operator machine, plus `uv`. `just ops deps`
  requires both, and installs everything else itself.

Five values cannot exist until something else is running, so they are filled in twice: the edge
node's mesh address (step 7), the backup B2 application key and the forge's own B2 key (step 8), the
Pocket ID API token (step 10) and Forgejo's OIDC client pair (step 11). Each is called out where it
lands. Blue runs forward through the thirteen steps, green marks the first and last, and each red
dashed arrow reaches back to a step that has to be revisited once the value it needed finally
exists.

```d2
direction: down

classes: {
  boundary: {
    style: {
      stroke-width: 3
      stroke: seagreen
      fill: honeydew
    }
  }
  backfill: {
    style: {
      stroke: firebrick
      stroke-dash: 4
    }
  }
}

stores: "1-2. The remote stores\nProton Pass vault, Infisical identities and folders" {
  class: boundary
}
repo: "3-6. This machine and this repo\njust ops setup, age key, node definitions,\nthe encrypted files, push"
hosts: "7-8. The hosts, the mesh, the bucket\njust ans setup, then just tf apply netbird, b2"
cluster: "9. The cluster\njust ans k8s: k3s, then Flux"
cloud: "10. The cloud plane\njust tf apply bunny, oidc"
forge: "11. The forge\njust ans setup brokkr --tags podman"
after: "12-13. Prove the isolation,\nthen accessTokenTrustedIps" { class: boundary }

stores -> repo -> hosts -> cluster -> cloud -> forge -> after

hosts -> repo: "MESH_IP was a placeholder in step 5.\nThe node had not joined the mesh yet" {
  class: backfill
}
hosts -> stores: "The backup B2 key was a placeholder in step 2.\ntofu/b2 mints it here" {
  class: backfill
}
cloud -> stores: "POCKETID_API_TOKEN was a placeholder in step 1.\nPocket ID did not exist yet" {
  class: backfill
}
forge -> repo: "Six brokkr fields were placeholders in step 1.\nSteps 8, 10 and 11 mint them" {
  class: backfill
}
```

The four red edges are the only backward ones, and they are why the phases are not simply a list.
Each of those values is produced by a step that needs a file written several steps earlier.

Step 11 is skippable in full. Nothing after it depends on the forge, and nothing in the cluster does
either, which is the property that node exists to have.

## 1. Proton Pass

Create a vault, named after the Infisical project so the two remote
stores are named alike. Then mint a **personal access token** in the Proton Pass web app. That
token, plus your GPG smartcard, is everything a new operator machine needs out of band.

```bash
PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_… pass-cli login
pass-cli info                        # session persists from here on
```

Replace `pst_…` with the token you just minted.

Generate the Flux deploy key now, since it is stored here:

```bash
ssh-keygen -t ed25519 -f /tmp/flux-deploy -N '' -C futhark-flux
```

Add `/tmp/flux-deploy.pub` to the repository's Deploy Keys on GitHub. Read-only is enough. Put the
private half in the vault as below, then `shred -u /tmp/flux-deploy*`.

Now the items. Nothing is matched by name here. Every consumer addresses a
`pass://<vault>/<item>/<field>` path, and the committed files that hold those paths are what this
table has to agree with. Item and field names are lowercase-with-spaces, per
[Naming](../conventions/secrets.md#naming).

| Item                       | Fields                                                                               | Value                                                                                                                             |
| -------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `flux`                     | `deploy key`                                                                         | The private half generated above                                                                                                  |
| `sops`                     | `age key`                                                                            | Generated at step 3                                                                                                               |
| `bunny`                    | `api key`                                                                            | Bunny account API key. Same permissions as cert-manager's DNS-01 webhook uses, since Bunny keys are account-wide, not zone-scoped |
| `pocketid`                 | `api token`                                                                          | Placeholder for now. Pocket ID does not exist yet, and step 10 fills it in                                                        |
| `netbird-enrollment`       | `token`                                                                              | A PAT on the **Admin** NetBird service user. Used by `ansible/roles/netbird` to mint node setup keys                              |
| `netbird-policy`           | `token`                                                                              | A PAT on a second, **Network Admin** service user, used by `tofu/netbird`                                                         |
| `healthchecks`             | one per node, named for the host                                                     | Each node's healthchecks.io ping URL, for [the mesh watchdog](../ansible/mesh-watchdog.md). Create the checks first               |
| `infisical-cluster-reader` | `client id`, `client secret`                                                         | The `cluster-reader` identity from step 2                                                                                         |
| `infisical-tofu-writer`    | `client id`, `client secret`                                                         | The `tofu-writer` identity from step 2                                                                                            |
| `infisical-backup-reader`  | `client id`, `client secret`                                                         | The `backup-reader` identity from step 2, the one path with an identity of its own                                                |
| `backblaze-tofu`           | `key id`, `application key`                                                          | A B2 application key for `tofu/b2`'s provider. Capabilities, and why it is not the master key: [b2](../tofu/b2.md)                |
| `backblaze-tofu-state`     | `key id`, `application key`, `state passphrase`                                      | A second B2 key restricted to `tofu/b2`'s state bucket, plus the passphrase state is encrypted under                              |
| `storagebox`               | `ssh key`                                                                            | The Storage Box key pair's private half, generated at [The rclone remotes](rclone.md#the-storage-box)                             |
| `rclone-crypt`             | `storagebox password`, `storagebox password2`, `gdrive password`, `gdrive password2` | The four obscured crypt passwords. Placeholders for now, since they are minted after step 3                                       |
| `brokkr-forgejo`           | `admin password`, `secret key`, `oidc client id`, `oidc client secret`               | The forge's break-glass account and its signing key. The two `oidc` fields are placeholders; step 11 fills them                   |
| `brokkr-woodpecker`        | `forge client id`, `forge client secret`, `agent secret`                             | The `forge` pair is placeholders. Forgejo itself issues them, at step 11                                                          |
| `brokkr-restic`            | `repository password`, `key id`, `application key`                                   | The forge's own restic repository. The two B2 fields are placeholders; step 8 mints them                                          |

Two NetBird PATs, on two **service users** of different roles, both created in the dashboard
before either token. The roles, and why they differ, are
[Bootstrap](../tofu/netbird.md#bootstrap) step 2. They expire, at most a year out. See
[Checks and CI](checks.md#netbird-token-expiry) for what each lapse breaks and
[Credential rotation](rotation.md#the-netbird-tokens) for the replacement procedure.

Create the NetBird account itself now, and delete its shipped `Default` policy. The full sequence
is [Bootstrap](../tofu/netbird.md#bootstrap). Leave that policy in place and the rules you apply
at step 8 describe an access model nothing is enforcing.

One `healthchecks` item holds every node's ping URL, one field per node named for the host, so
adding a node is adding a field. Create each check in healthchecks.io first, with period 2 minutes
and grace 15 minutes, which is past the ladder's restart and re-up rungs and short of its reboot
rung. A node whose field is missing still runs its watchdog, it just reports nothing.

The three `brokkr-*` items are only needed if you are building a `workflow: podman` node. Skip them
otherwise, and skip that node's field on `healthchecks` too. Four of their ten fields you generate
now, with a password manager or `openssl rand -base64 48`:

| Field                               | Is                                                                                 |
| ----------------------------------- | ---------------------------------------------------------------------------------- |
| `brokkr-forgejo/admin password`     | The local admin's password. Long: it is the account that survives a cluster outage |
| `brokkr-forgejo/secret key`         | Forgejo's `SECRET_KEY`, which signs its own tokens                                 |
| `brokkr-woodpecker/agent secret`    | Shared between the Woodpecker server and its agent. Not read by anything else      |
| `brokkr-restic/repository password` | Encrypts the forge's backups. **Losing it loses every forge snapshot**             |

The admin's _username_ goes in `config/sops/ops.sops.yaml` rather than here, as
`ansible.secrets.brokkr.FORGEJO_ADMIN_USER`. It grants nothing on its own but is identifying, so it
cannot be an `Environment=` line in a committed unit file.

The remaining six cannot exist yet, because nothing has minted them: `tofu/b2` mints the two
`brokkr-restic` B2 fields at step 8, `tofu/oidc` mints the two `brokkr-forgejo` `oidc` fields at step
10, and Forgejo itself issues the two `forge` fields on `brokkr-woodpecker` at step 11. Leave all six as
placeholders and finish them at [step 11](#11-the-forge), which lists the command that prints each.

`brokkr-restic/repository password` deserves the same treatment as the cluster's restic password: it
is the one credential here with no second copy anywhere, by construction, and there is no recovery
path if it is lost. See [Backup and recovery](recovery.md#brokkr).

`storagebox` and `rclone-crypt` are the items in the table no committed `pass://` reference points
at. Their consumers read Infisical, not the vault, so these copies exist only so the credentials
are recoverable, and you retype them into `/infra/csi-rclone`. For the crypt passwords that is not
a convenience: lose one and the data it wrapped is ciphertext forever.

Three Infisical identities, not one, for the same reason, and a sharper one. `cluster-reader` is
seeded into the cluster and `tofu-writer` never leaves this machine, so collapsing them would hand
the cluster a write credential. `backup-reader` is split off for a different reason again: the
cluster's read credential must not also be the one that decrypts B2.

**The admin SSH private key goes in no store at all.** Ansible authenticates with your own
`~/.ssh` identity rather than reading it, and only its public half is committed, SOPS-encrypted,
at step 4.

Nothing here is committed. What the repository holds is the map: `pass://<vault>/<item>/<field>`
references, already written into `config/sops/ops.sops.yaml.example`, so unless you named the vault
something other than the name the templates assume there is nothing to edit in that half. You seal the file at
[step 5](#5-the-encrypted-files), sealed to your GPG key only and never the cluster age key. The
reasoning is in
[Secrets](../conventions/secrets.md#why-the-operator-store-is-separate).

## 2. Infisical

Sign up at **eu.infisical.com**. That is a separate data region, not a mirror of
`app.infisical.com`, and an account on one is invisible to the other. Create a project `futhark`
with a `prod` environment.

Create three Universal Auth machine identities. With yourself that is 4 of the 5 the free tier
allows:

- **`cluster-reader`**: read-only on the whole project, **denied** `/infra/k8up`. Leave
  `accessTokenTrustedIps` alone for now. You set it at step 13, once the cluster has an egress
  address.
- **`tofu-writer`**: write on the node folders the two writing modules target, and nothing else.
  Today that is `/nodes/kenaz/actual`, `/nodes/kenaz/open-webui`, `/nodes/kenaz/linkwarden`,
  `/nodes/kenaz/bifrost`, `/nodes/kenaz/vane` and `/nodes/kenaz/kvasir`. See
  [oidc](../tofu/oidc.md) and [bifrost](../tofu/bifrost.md). Widen it as a module gains a folder,
  never to the whole project.
- **`backup-reader`**: read on `/infra/k8up` and nothing else. The split is deliberate. Losing
  the cluster's read credential must not also mean losing the ability to decrypt B2. See
  [Secrets](../conventions/secrets.md).

Copy all three client ID and secret pairs into Proton Pass per the table above.

Then create the folders and secrets. Names are `SCREAMING_SNAKE_CASE` throughout, per
[Naming](../conventions/secrets.md#naming):

| Folder                    | Secrets                                                                                                     | Consumed by                                                                                                                                       |
| ------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/infra/cert-manager`     | `BUNNY_API_KEY`                                                                                             | `infra/cert-manager/config/secret.yaml`                                                                                                           |
| `/infra/csi-rclone`       | 11 secrets, `STORAGEBOX_*` and `GDRIVE_*`, listed in [The rclone remotes](rclone.md#the-artifact)           | `infra/storage/app/secret.yaml`                                                                                                                   |
| `/infra/monitoring`       | `ADMIN_USER`, `ADMIN_PASSWORD`, `SLACK_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL`, `GRAFANA_DB_PASSWORD`         | `infra/monitoring/app/grafana/secret.yaml`                                                                                                        |
| `/infra/auth`             | `POCKETID_ENCRYPTION_KEY`, `MAXMIND_LICENSE_KEY`, `SSO_COOKIE_SECRET`, `POSTGRES_PASSWORD`                  | `infra/auth/app/*infisicalsecret.yaml`                                                                                                            |
| `/infra/gatus`            | `POSTGRES_PASSWORD`                                                                                         | `infra/gatus/app/infisicalsecret.yaml`                                                                                                            |
| `/infra/glance`           | `NETBIRD_API_KEY`, `GITHUB_TOKEN`, `WAQI_TOKEN`                                                             | `infra/glance/app/infisicalsecret.yaml`                                                                                                           |
| `/infra/k8up`             | `B2_KEY_ID`, `B2_APPLICATION_KEY`, `RESTIC_PASSWORD`                                                        | `infra/backup/app/secret.yaml`, read as `backup-reader`                                                                                           |
| `/nodes/kenaz/actual`     | none, leave empty                                                                                           | written by `just tf apply oidc`                                                                                                                   |
| `/infra/postgres`         | one `<TENANT>_POSTGRES_PASSWORD` per tenant: `LINKWARDEN_`, `GRAFANA_`, `GATUS_`, `OPENWEBUI_`, `POCKETID_` | `infra/postgres/config/infisicalsecret.yaml`                                                                                                      |
| `/nodes/kenaz/linkwarden` | `NEXTAUTH_SECRET`, `POSTGRES_PASSWORD`                                                                      | `nodes/kenaz.k8s/linkwarden/app/infisicalsecret.yaml`. The two `OIDC_*` keys are written by `just tf apply oidc`                                  |
| `/nodes/kenaz/open-webui` | `WEBUI_SECRET_KEY`, `POSTGRES_PASSWORD`                                                                     | `nodes/kenaz.k8s/open-webui/app/infisicalsecret.yaml`. `OAUTH_*` is written by `just tf apply oidc`, `OPENAI_API_KEYS` by `just tf apply bifrost` |
| `/nodes/kenaz/bifrost`    | `BIFROST_ENCRYPTION_KEY`, `BIFROST_ADMIN_USERNAME`, `BIFROST_ADMIN_PASSWORD`, `OLLAMA_API_KEY`              | `nodes/kenaz.k8s/bifrost/app/infisicalsecret.yaml`. The four `VK_*` keys in this folder are written by `just tf apply bifrost`                    |
| `/nodes/kenaz/vane`       | none, leave empty                                                                                           | written by `just tf apply bifrost`                                                                                                                |
| `/nodes/kenaz/kvasir`     | none, leave empty                                                                                           | written by `just tf apply bifrost`                                                                                                                |

Every database password appears twice on purpose: once in `/infra/postgres`, where CloudNativePG
creates the role, and once in the consuming app's own folder, where it is assembled into a
connection string. The admission policy confines each namespace to its own tier's folder, so
neither side can read the other's. Type the same value into both. Generate them from letters and
digits only, because each is interpolated into a URL. See
[The shared database](../gitops/infra.md#the-shared-database).

`B2_KEY_ID` and `B2_APPLICATION_KEY` are placeholders for now. `tofu/b2` mints that key at step 8.
`RESTIC_PASSWORD` is yours to generate, from `openssl rand -base64 32`, and it must exist before
the first backup runs: it is baked into the repository at creation. **Lose it and the backups are
ciphertext forever**, which is the point of it. The durability table is in
[Backup and recovery](recovery.md).

That table goes stale as apps are added. The authoritative version is the tree itself: every
`InfisicalStaticSecret` names its `secretPath`, and any that remaps a key names the Infisical
secret in its `template` block.

```bash
grep -rl 'kind: InfisicalStaticSecret' infra nodes
```

One NetBird credential appears in that table, and exactly one may. `NETBIRD_API_KEY` is read by
Glance's peers widget and by nothing else, so it belongs to its own service user with no write
capability: the worst an attacker who reads it can do is list peers. The two PATs that can change
the mesh, `netbird-policy` and `netbird-enrollment`, stay on the operator machine and never enter
the cluster. See [Credential rotation](rotation.md#the-netbird-tokens).

`POCKETID_ENCRYPTION_KEY` and `SSO_COOKIE_SECRET` are both new material, each
`openssl rand -base64 32`. The cookie secret additionally has to be URL-safe, so pipe it through
`tr -- '+/' '-_'`. Both must exist before their Deployment first reconciles.

`/infra/csi-rclone` is the one row you cannot fill in yet. Two of its values are minted by `rclone`
and four more are generated with it, and `rclone` arrives with `just ops setup` at step 3, so create
the folder now, leave it empty, and come back after that step. It also needs a Hetzner Storage Box
and a Google OAuth client that nothing else in this bootstrap creates.
[The rclone remotes](rclone.md) is the whole procedure, end to end.

## 3. The operator machine

`just` runs everything else here, so it has to come first. Nothing can install its own runner:

```bash
sudo dnf install just
just ops setup
```

That installs `ansible-core`, `ansible-lint`, `yamllint`, `kubectl`, `helm`, `kustomize`,
`flux`, `rclone`, `b2`, `tofu`, `netbird`, `pre-commit`, `sops`, `age`, `pass-cli`, the
GPG smartcard stack, and `mdbook` with `d2` and `mdbook-d2` for the diagrams. It also installs the
pre-commit hooks, runs `tofu init` in every module but `b2`, and checks you have a Proton Pass
session and a place on the mesh. `b2` is skipped with a message, since its remote backend
authenticates against secrets step 5 has not written yet. Step 8 initialises it.

Most of those are pinned in `mise.toml` and installed by `mise`, which puts them in
`~/.local/share/mise/shims` rather than on `PATH`. Put that directory on `PATH` in your login
profile, not only in an interactive shell configuration. The `kustomize build`, `just --fmt` and
`tofu validate` pre-commit hooks run outside an interactive shell and call those binaries by name:

```bash
echo 'export PATH="$HOME/.local/share/mise/shims:$PATH"' >> ~/.profile
```

Verify from a shell that has read the new profile:

```bash
kustomize version
```

It prints the `kustomize` version in `mise.toml`. If the command is not found, `PATH` has not
picked up the shims, and pre-commit will fail on the `kustomize build` hook.

`rclone` and `b2` are the two there purely for bootstrap. Nothing in `just` calls either.
`rclone` exists so you can go back and finish [The rclone remotes](rclone.md) from step 2, and
`b2` so you can create the state bucket and the two application keys that
[b2](../tofu/b2.md#before-the-first-apply) needs before step 8 can run.

You need two things of your own: the GPG smartcard plugged in, and the Proton Pass session from
step 1. The third, this machine's own membership of the mesh, is what `just ops mesh` checks.
`k8s_cluster` resolves each node's mesh address through NetBird's DNS from here. The client
arrives with `just ops deps`, but joining does not. Run the `netbird up` that `just ops mesh`
prints, since it carries the `--interface-name` this repository uses, log in over SSO, then add
the peer to the `admin` group from the dashboard, per
[netbird](../tofu/netbird.md#bootstrap).

On a cold bootstrap that check is **expected to fail here**. The NetBird account has an
`admin` group only after step 8, so there is nothing to join yet. It is the last thing
`ops setup` runs, so everything above it has already happened. Come back and re-run
`just ops mesh` once step 8 is done. Nothing between here and step 9 needs the mesh.

Then generate the cluster age key:

```bash
just ops age-key
```

Put the printed `age1…` recipient into `.sops.yaml`, replacing
`AGE_CLUSTER_RECIPIENT_PLACEHOLDER`. Store the private key in Proton Pass as the `age key` field
of the `sops` item, then shred the temporary file the recipe names. Why this key is separate from
your GPG key, and what it can and cannot open, is in
[Secrets](../conventions/secrets.md#sops).

Verify: `.sops.yaml` no longer contains `AGE_CLUSTER_RECIPIENT_PLACEHOLDER`, and the temporary
key file is gone.

## 4. Node definitions

One `ansible/nodes/<hostname>/host.yml` per machine, symlinked into
`ansible/inventory/host_vars/<hostname>/`, and the hostname listed in
`ansible/inventory/hosts.yml`. Each machine's address goes in `config/sops/ops.sops.yaml` at
[step 5](#5-the-encrypted-files). The schema and exact commands are in
[Nodes](../ansible/nodes.md#adding-a-node).

## 5. The encrypted files

Two encrypted files, each shipping as a `.example` template. Ask which are still missing, then
work through them:

```bash
just ops sops                    # lists what has no real file yet
just ops sops <file>             # copies the template, opens it, encrypts on save
```

Re-run the same command later to edit one. It decrypts and re-encrypts around your editor, and it
fails closed: an aborted edit or a failed encrypt removes the plaintext rather than leaving it at
a `*.sops.*` path.

Both templates arrive with every `pass://` reference already written, so only the identifying half
needs filling in.

`config/sops/ops.sops.yaml`, sealed to your GPG key only:

- `ansible.admin`: the admin user's name and SSH public key.
- `ansible.secrets`: nothing to change beyond the vault name, per [step 1](#1-proton-pass).
- `ansible.secrets.brokkr`: the forge node's runtime secrets, if you are building one. Eleven keys,
  ten of them `pass://` references into the three `brokkr-*` items from step 1 and one,
  `FORGEJO_ADMIN_USER`, a literal. Six of those references point at fields nothing has minted yet:
  the two `FORGEJO_OIDC_*`, the two `WOODPECKER_FORGE_*` and the two `B2_*`. The references are still
  correct, so write them all now; it is the Proton Pass fields behind six of them that stay
  placeholders until [step 11](#11-the-forge).
- `nodes.<hostname>.ip`: that node's public address. Leave `mesh_ip` empty. The node has not
  joined the mesh yet, and `roles/netbird` writes it in at step 7.
- `brokkr.B2_BUCKET`: the forge node's own restic bucket, separate from the cluster's. Read by both
  Ansible and `tofu/b2`, which is why it is top level rather than inside either plane's section. Omit
  the key entirely if you are not building that node.
- `tofu.<module>`: each module's own credentials and identifying values. `netbird` needs its PAT,
  `bunny` its API key, `oidc` the Pocket ID base URL and the Infisical project ID, `b2` its two
  key pairs, the state passphrase and the state bucket.

`config/sops/cluster.sops.yaml`, sealed to the cluster age key as well, holding one `cluster-values`
Secret:

- `DOMAIN`, `SUB_INTERNAL`, `SUB_NODES`: the base domain and its subdomain labels. Flux, all four
  tofu modules and Ansible read these, and nothing else spells a domain out. See
  [Domains](../conventions/domains.md).
- `PUBLIC_IP`, `MESH_IP`: the edge node's addresses. **Put a placeholder in `MESH_IP` for now**,
  because the node has not joined the mesh yet. Step 7 fills it.
- `B2_BUCKET`, `B2_REGION`: where the restic repository lives.

No `tofu.<module>` section carries a node address or a domain. Each module declares those in its
`refs.env` and reads them from whichever of the two files owns them, at plan and apply time. See
[Values another plane owns](../tofu/index.md#values-another-plane-owns).

Nothing builds until `config/sops/cluster.sops.yaml` exists. `config/kustomization.yaml` references
it, so `kustomize build` fails without it. That is deliberate: better a loud failure than a
cluster reconciling with half its inputs missing.

## 6. Verify and push

```bash
pre-commit run --all-files
```

Everything must pass, including `kustomize build` and `sops-encrypted`. The latter is the one that
catches a plaintext committed by mistake. `gitleaks` will not, because a node address matches no
credential pattern.

Then commit and **push**. Flux reconciles from the remote, not from your working tree, and an
unpushed commit is invisible to the cluster.

## 7. Host provisioning

```bash
just ans setup '' --skip-tags podman
```

Update, admin user, SSH hardening, mesh join, firewall. Pass a hostname as the first argument to
limit it to one machine; `''` means all of them, and anything after it goes to `ansible-playbook`.
Safe to re-run.

`--skip-tags podman` matters only if you are building a `workflow: podman` node. That plane needs
credentials no step before this one has minted, so it is deferred to
[step 11](#11-the-forge). On a cluster-only fleet the flag is a no-op and
plain `just ans setup` is equivalent. `ssh_identity` picks whichever login currently answers, and after the first run
each host answers only as the admin user on the hardened port. Provisioning nodes one at a time is
fine, because the mesh-peer resolution in `roles/netbird` retries while the new peer's DNS record
propagates.

Each host's mesh address is read back out of `netbird status --json` and written into
`nodes.<hostname>.mesh_ip` in `config/sops/ops.sops.yaml` by the same run, so `just ans setup` leaves
that file modified. Commit it. `playbooks/k8s.yml` reads the value from there, and `tofu/bunny`
gets the public address from the same map.

`MESH_IP` in `config/sops/cluster.sops.yaml` is the edge node's copy of that address, and Flux cannot
read the operator store, so it still needs filling by hand:

```bash
ssh <edge host> netbird status --json | jq -r .netbirdIp
just ops sops config/sops/cluster.sops.yaml     # set MESH_IP
git commit -am 'fix(cluster-values): real mesh address' && git push
```

Verify: each host answers as the admin user on the hardened port, and
`ssh <host> netbird status` reports the peer connected.

## 8. Mesh policy, and the backup bucket

Both before the cluster, not after. Cross-node pod networking needs the all-protocol node-to-node
rule, and without it the cluster fails in ways that look like anything but a network fault.

```bash
just tf init netbird
just tf plan netbird && just tf apply netbird
```

Read [netbird](../tofu/netbird.md) first. Three things this step needs that it cannot check for
you:

- The account's shipped `Default` policy has to be gone, from step 1.
- The `netbird-policy` service user has to be at **Admin** for this apply, because it creates
  `netbird_account_settings` and Network Admin cannot write account settings. Promote it, apply,
  then demote it again. The procedure is
  [Applying account settings](../tofu/netbird.md#applying-account-settings).
- Nothing validates a policy server-side. NetBird has no policy tests, so a wrong rule applies
  cleanly and fails later, in traffic.

This also sets the account's peer DNS domain and network range, so do it before any node joins. A
peer registered under the old ones has to re-register.

The DNS zone it creates resolves `*.$SUB_INTERNAL.$DOMAIN` to the ingress node's mesh address,
read from `["nodes"]["<host>"]["mesh_ip"]` per `tofu/netbird/refs.env`. That is why this step comes
after step 7: the value is empty until `roles/netbird` records it, and an empty one fails the
apply. Nothing answers on that address yet, which is fine. The record is static, and the name
starts answering usefully once step 9 brings `traefik-internal` up on it.

Then the bucket the backups live in, and the key K8up uses:

```bash
just tf init b2
just tf plan b2 && just tf apply b2
```

Read [b2](../tofu/b2.md) first. It needs a state bucket and a state passphrase created by hand, and if a
bucket already exists it has to be imported rather than created. File the two outputs into
Infisical `/infra/k8up` as `B2_KEY_ID` and `B2_APPLICATION_KEY`, replacing the placeholders from
step 2. Do this before the cluster, because `infra/backup` reconciles at step 9 and reads them
there. Get it wrong and the symptom is every K8up job failing against a repository it cannot
open.

If you declared `brokkr.B2_BUCKET` at step 5, this apply also created the forge's bucket and its
scoped key. That pair goes to **Proton Pass**, not Infisical, because the node that reads it holds no
store credential:

```bash
just tf output b2 -raw brokkr_b2_key_id           # -> brokkr-restic/key id
just tf output b2 -raw brokkr_b2_application_key  # -> brokkr-restic/application key
```

Filing them now completes two of the four placeholders left at step 5.

Verify:

```bash
just tf plan netbird     # no changes
just tf plan b2          # no changes
just ops mesh            # this machine is on the mesh now
```

## 9. Cluster and Flux

```bash
just ans k8s
```

Installs k3s from inventory, the controller first and then the workers, and bootstraps Flux,
including the Secrets that cannot come from Flux because Flux needs them to resolve anything
else. The `local-path` StorageClass comes up with k3s itself. The full sequence is in
[Bootstrap and reconciliation](../gitops/flux.md#bootstrap-sequence).

The kubeconfig lands at `ansible/.generated/kubeconfig`, mode 0600, gitignored. Every `ks` and
`fx` recipe points at it automatically.

```bash
just ks status
just fx failing
```

Expect several minutes. Certificate issuance in particular waits on DNS-01 propagation.

Verify: `just fx failing` is empty and `just ks certs` shows every certificate `Ready`. Anything
still failing after that, start at [Troubleshooting](troubleshooting.md).

## 10. The cloud plane

Pocket ID is running now, so create its admin API key at **Settings → Admin → API Keys** on
`auth.$DOMAIN`, and replace the `POCKETID_API_TOKEN` placeholder from step 1.

`tofu/oidc` and `tofu/bifrost` write into Infisical at paths the cluster is already watching,
which is why they go last.

```bash
just tf plan bunny   && just tf apply bunny
just tf plan oidc    && just tf apply oidc
just tf plan bifrost && just tf apply bifrost
```

Each has its own prerequisites. See [bunny](../tofu/bunny.md), [oidc](../tofu/oidc.md) and
[bifrost](../tofu/bifrost.md).

Verify: all three plans are no-ops on a second run, the Actual app picks up its OIDC client from
`/nodes/kenaz/actual` without further edits, and `VK_OPEN_WEBUI` in `/nodes/kenaz/bifrost` holds
the same value as `OPENAI_API_KEYS` in `/nodes/kenaz/open-webui`.

`cli-proxy-api` serves no model until an account is linked, which is a browser flow rather than an
apply. See [CLI proxy login](cli-proxy-login.md).

## 11. The forge

Skip this step if you are not building a `workflow: podman` node.

It comes last because it depends on almost everything before it, and on nothing after. `tofu/bunny`
at step 10 published `git.$DOMAIN` and `ci.$DOMAIN`; `tofu/oidc` at the same step minted Forgejo's
Pocket ID client, which needed Pocket ID running from step 9; `tofu/b2` at step 8 created the bucket.
Nothing in the cluster depends on this node in return, which is the whole point of it.

Six Proton Pass fields were left as placeholders at step 1. Four can be filled now, and the last two
only after Forgejo is running, which is why this step doubles back on itself.

| Field                                   | Where it comes from                                   |
| --------------------------------------- | ----------------------------------------------------- |
| `brokkr-restic/key id`                  | `just tf output b2 -raw brokkr_b2_key_id`             |
| `brokkr-restic/application key`         | `just tf output b2 -raw brokkr_b2_application_key`    |
| `brokkr-forgejo/oidc client id`         | `just tf output oidc -raw forgejo_oidc_client_id`     |
| `brokkr-forgejo/oidc client secret`     | `just tf output oidc -raw forgejo_oidc_client_secret` |
| `brokkr-woodpecker/forge client id`     | Forgejo's own OAuth application list, below           |
| `brokkr-woodpecker/forge client secret` | The same                                              |

If you already filed the two `brokkr-restic` fields at step 8, only the two `oidc` ones are
outstanding here:

```bash
just tf output oidc -raw forgejo_oidc_client_id      # -> brokkr-forgejo/oidc client id
just tf output oidc -raw forgejo_oidc_client_secret  # -> brokkr-forgejo/oidc client secret
```

Then converge the plane that was skipped at step 7:

```bash
just ans setup brokkr --tags podman
```

That installs Podman, opens 443 and 22, writes the env files, initialises the restic repository,
clones this repository, starts every container from the units in `nodes/brokkr.podman/units/`, and
creates the local admin plus the Pocket ID login source.

The two `forge` fields on `brokkr-woodpecker` are still placeholders at this point, and they are the one
credential here no plane in this repository can mint: Woodpecker authenticates against Forgejo, and
Forgejo issues it. Forgejo has to be running first, which it now is. Woodpecker comes up unable to
complete a login until you create them:

1. Log in to `https://git.$DOMAIN` as the local admin.
2. **Settings → Applications → Create OAuth2 application**, redirect URI
   `https://ci.$DOMAIN/authorize`.
3. File the id and secret into the Proton Pass `brokkr-woodpecker` item.
4. Re-run `just ans setup brokkr --tags podman`.

Verify, and the fourth item is the one that matters:

```bash
ssh brokkr podman ps                                 # five containers, all Up
curl -sI https://git.$DOMAIN | head -1               # 200, Let's Encrypt certificate
ssh brokkr systemctl start futhark-forge-backup.service
ssh brokkr journalctl -u futhark-forge-backup -n 20  # a restic snapshot id
```

Then, in a browser: `git.$DOMAIN` offers "Sign in with pocketid" **and no sign-up form**, the local
admin password logs in, `ci.$DOMAIN` completes the Forgejo OAuth round trip, and a trivial
`.woodpecker.yaml` in a test repository runs a step to completion.

Last, prove the property the node exists for. Scale Pocket ID to zero and confirm the local admin
still logs in:

```bash
flux suspend kustomization auth && kubectl -n auth scale deploy/pocketid --replicas=0
# log in at git.$DOMAIN as the local admin
kubectl -n auth scale deploy/pocketid --replicas=1 && flux resume kustomization auth
```

If that fails, the node is decoration. Everything else about it is in
[The standalone Podman plane](../gitops/podman.md).

Set the `GIT_MIRROR_BROKKR` repository variable and the `GIT_MIRROR_BROKKR_KEY` secret on GitHub to
have `.github/workflows/mirror.yml` push a mirror here nightly. Until they are set that job skips.

## 12. Prove the isolation holds

The tier boundary is enforced by RBAC and an admission policy rather than by a secret store's own
namespaces, so it is worth confirming rather than assuming. Both checks are in
[Checks and CI](checks.md#infisical-tier-isolation). The admission one is the important half: an
`InfisicalStaticSecret` in a node namespace asking for an `/infra` path must be **rejected at
admission**, not merely fail to sync.

Delete the probe objects afterwards.

## 13. Aftercare

Set `accessTokenTrustedIps` on the `cluster-reader` identity to the cluster's egress address. It
is the only server-side constraint available on a single shared credential, and
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced) explains why
there is only one.

Then decommission whatever store these values came from, and confirm nothing still points at it:

```bash
grep -rn 'pass://' --exclude-dir=.git .
```

Install the Kvasir pipe function in Open WebUI. Nothing reconciles this: Open WebUI keeps its
Functions in its own database, and `ENABLE_PERSISTENT_CONFIG=False` governs its settings, not these.
A rebuilt cluster therefore has a running `kvasir` that no client can reach until this is repeated.
What does cover it is the `open-webui` backup Schedule, since the function is a row in that
database.

In Admin Panel then Functions, open the menu beside **+**, choose **Import From Link**, and paste
`https://github.com/brewcoua/kvasir/releases/latest/download/pipe.py`. Importing runs that file on
the server, so read it first, or verify it came from that repository's build:

```bash
gh release download --pattern pipe.py --repo brewcoua/kvasir
gh attestation verify pipe.py --repo brewcoua/kvasir
```

Set the function id to `kvasir`, which is what prefixes its models, then set its `KVASIR_URL` valve
to `http://kvasir.kvasir.svc.cluster.local:8080`. The shipped default is `http://kvasir:8080`,
which does not resolve from another namespace. Enable the function: `kvasir.storm` and
`kvasir.co-storm` then appear in the model picker.

Use the `storm` half. Co-STORM works, but this cluster gives Kvasir an `emptyDir` for its sessions,
so a round table lasts only until the pod restarts. See
[Node apps](../gitops/nodes.md#the-search-surface).

Finally, put the two NetBird PAT expiry dates in a calendar. Nothing here tracks them. See
[Credential rotation](rotation.md).
