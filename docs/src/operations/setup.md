# Cold bootstrap

Build the whole thing from nothing, in order. At the end you have provisioned hosts on a NetBird
mesh, a k3s cluster reconciling from this repository through Flux, every runtime secret resolving
from Infisical, and nightly backups reaching Backblaze B2.

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

Three values cannot exist until something else is running, so they are filled in twice: the edge
node's mesh address (step 7), the backup B2 application key (step 8) and the Pocket ID API token
(step 10). Each is called out where it lands. Blue runs forward through the twelve steps, green
marks the first and last, and each red dashed arrow reaches back to a step that has to be
revisited once the value it needed finally exists.

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
after: "11-12. Prove the isolation,\nthen accessTokenTrustedIps" { class: boundary }

stores -> repo -> hosts -> cluster -> cloud -> after

hosts -> repo: "MESH_IP was a placeholder in step 5.\nThe node had not joined the mesh yet" {
  class: backfill
}
hosts -> stores: "The backup B2 key was a placeholder in step 2.\ntofu/b2 mints it here" {
  class: backfill
}
cloud -> stores: "POCKETID_API_TOKEN was a placeholder in step 1.\nPocket ID did not exist yet" {
  class: backfill
}
```

The three red edges are the only backward ones, and they are why the phases are not simply a list.
Each of those values is produced by a step that needs a file written several steps earlier.

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
  `accessTokenTrustedIps` alone for now. You set it at step 12, once the cluster has an egress
  address.
- **`tofu-writer`**: write on `/nodes/kenaz/actual` only.
- **`backup-reader`**: read on `/infra/k8up` and nothing else. The split is deliberate. Losing
  the cluster's read credential must not also mean losing the ability to decrypt B2. See
  [Secrets](../conventions/secrets.md).

Copy all three client ID and secret pairs into Proton Pass per the table above.

Then create the folders and secrets. Names are `SCREAMING_SNAKE_CASE` throughout, per
[Naming](../conventions/secrets.md#naming):

| Folder                | Secrets                                                                                           | Consumed by                                             |
| --------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `/infra/cert-manager` | `BUNNY_API_KEY`                                                                                   | `infra/cert-manager/config/secret.yaml`                 |
| `/infra/csi-rclone`   | 11 secrets, `STORAGEBOX_*` and `GDRIVE_*`, listed in [The rclone remotes](rclone.md#the-artifact) | `infra/storage/app/secret.yaml`                         |
| `/infra/monitoring`   | `ADMIN_USER`, `ADMIN_PASSWORD`, `SLACK_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL`                      | `infra/monitoring/app/grafana/secret.yaml`              |
| `/infra/auth`         | `POCKETID_ENCRYPTION_KEY`, `MAXMIND_LICENSE_KEY`, `SSO_COOKIE_SECRET`                             | `infra/auth/app/*infisicalsecret.yaml`                  |
| `/infra/glance`       | `NETBIRD_API_KEY`, `GITHUB_TOKEN`, `WAQI_TOKEN`, `NASA_API_KEY`                                   | `infra/glance/app/infisicalsecret.yaml`                 |
| `/infra/k8up`         | `B2_KEY_ID`, `B2_APPLICATION_KEY`, `RESTIC_PASSWORD`                                              | `infra/backup/app/secret.yaml`, read as `backup-reader` |
| `/nodes/kenaz/actual` | none, leave empty                                                                                 | written by `just tf apply oidc`                         |

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
- `nodes.<hostname>.ip`: that node's public address. Leave `mesh_ip` empty. The node has not
  joined the mesh yet, and `roles/netbird` writes it in at step 7.
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
just ans setup
```

Update, admin user, SSH hardening, mesh join, firewall. Add `<host>` to limit it to one machine.
Safe to re-run. `ssh_identity` picks whichever login currently answers, and after the first run
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

`tofu/oidc` writes into Infisical at the path the cluster is already watching, which is why it
goes last.

```bash
just tf plan bunny && just tf apply bunny
just tf plan oidc  && just tf apply oidc
```

Each has its own prerequisites. See [bunny](../tofu/bunny.md) and [oidc](../tofu/oidc.md).

Verify: both plans are no-ops on a second run, and the Actual app picks up its OIDC client from
`/nodes/kenaz/actual` without further edits.

## 11. Prove the isolation holds

The tier boundary is enforced by RBAC and an admission policy rather than by a secret store's own
namespaces, so it is worth confirming rather than assuming. Both checks are in
[Checks and CI](checks.md#infisical-tier-isolation). The admission one is the important half: an
`InfisicalStaticSecret` in a node namespace asking for an `/infra` path must be **rejected at
admission**, not merely fail to sync.

Delete the probe objects afterwards.

## 12. Aftercare

Set `accessTokenTrustedIps` on the `cluster-reader` identity to the cluster's egress address. It
is the only server-side constraint available on a single shared credential, and
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced) explains why
there is only one.

Then decommission whatever store these values came from, and confirm nothing still points at it:

```bash
grep -rn 'pass://' --exclude-dir=.git .
```

Finally, put the two NetBird PAT expiry dates in a calendar. Nothing here tracks them. See
[Credential rotation](rotation.md).
