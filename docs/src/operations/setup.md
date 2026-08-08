# Cold bootstrap

Building the whole thing from nothing, in order. Every step is re-runnable.

Three values cannot exist until something else is running, so they are filled in twice: the edge
node's mesh address (step 7), Velero's B2 application key (step 8) and the Pocket ID API token
(step 10). Each is called out where it lands.

```d2
direction: down

stores: "1-2. The remote stores\nProton Pass vault, Infisical identities and folders"
repo: "3-6. This machine and this repo\njust ops setup, age key, node definitions,\nthe encrypted files, push"
hosts: "7-8. The hosts, the mesh, the bucket\njust ans setup, then just tf apply netbird, b2"
cluster: "9. The cluster\njust ans k0s — k0sctl, local-path, Flux"
cloud: "10. The cloud plane\njust tf apply bunny, oidc"
after: "11-12. Prove the isolation,\nthen accessTokenTrustedIps"

stores -> repo -> hosts -> cluster -> cloud -> after

hosts -> repo: "MESH_IP was a placeholder in step 5 —\nthe node had not joined the mesh yet" {
  style: { stroke-dash: 4; stroke: "#c00" }
}
hosts -> stores: "Velero's B2 key was a placeholder in step 2 —\ntofu/b2 mints it here" {
  style: { stroke-dash: 4; stroke: "#c00" }
}
cloud -> stores: "POCKETID_API_TOKEN was a placeholder in step 1 —\nPocket ID did not exist yet" {
  style: { stroke-dash: 4; stroke: "#c00" }
}
```

The three red edges are the only backward ones, and they are why the phases are not simply a
list: each of those values is produced by a step that needs a file written several steps earlier.

## 1. Proton Pass

Create a vault named **`futharkd`** — the same slug as the Infisical project, so the two remote
stores are named alike. Then mint a **personal access token** in the Proton Pass web app; that
token, plus your GPG smartcard, is everything a new operator machine needs out of band.

```bash
PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_… pass-cli login
pass-cli info                        # session persists from here on
```

Generate the Flux deploy key now, since it is stored here:

```bash
ssh-keygen -t ed25519 -f /tmp/flux-deploy -N '' -C futhark-flux
```

Add `/tmp/flux-deploy.pub` to the repository's Deploy Keys on GitHub (read-only is enough), put
the private half in the vault as below, then `shred -u /tmp/flux-deploy*`.

Now the items. Nothing is matched by name here — every consumer addresses a
`pass://futharkd/<item>/<field>` path, and the committed files that hold those paths are what
this table has to agree with. Item and field names are lowercase-with-spaces, per
[Naming](../conventions/secrets.md#naming).

| Item                       | Fields                                                                               | Value                                                                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `flux`                     | `deploy key`                                                                         | The private half generated above                                                                                             |
| `sops`                     | `age key`                                                                            | Generated at step 3                                                                                                          |
| `bunny`                    | `api key`                                                                            | Bunny account API key. Same permissions as cert-manager's DNS-01 webhook uses — Bunny keys are account-wide, not zone-scoped |
| `pocketid`                 | `api token`                                                                          | Placeholder for now — Pocket ID does not exist yet. Filled in at step 10                                                     |
| `netbird-enrollment`       | `token`                                                                              | A PAT on the NetBird service user. Used by `ansible/roles/netbird` to mint node setup keys                                   |
| `netbird-policy`           | `token`                                                                              | A **second** PAT on the same service user, used by `tofu/netbird`                                                            |
| `healthchecks`             | one per node, named for the host                                                     | Each node's healthchecks.io ping URL, for [the mesh watchdog](../ansible/mesh-watchdog.md). Create the checks first          |
| `infisical-cluster-reader` | `client id`, `client secret`                                                         | The `cluster-reader` identity from step 2                                                                                    |
| `infisical-tofu-writer`    | `client id`, `client secret`                                                         | The `tofu-writer` identity from step 2                                                                                       |
| `infisical-backup-reader`  | `client id`, `client secret`                                                         | The `backup-reader` identity from step 2 — the one path with an identity of its own                                          |
| `backblaze-tofu`           | `key id`, `application key`                                                          | A B2 application key for `tofu/b2`'s provider. Capabilities, and why it is not the master key: [b2](../tofu/b2.md)           |
| `backblaze-tofu-state`     | `key id`, `application key`, `sse-c key`                                             | A second B2 key restricted to `tofu/b2`'s state bucket, plus the key that state is encrypted under                           |
| `storagebox`               | `ssh key`                                                                            | The Storage Box key pair's private half, generated at [The rclone remotes](rclone.md#the-storage-box)                        |
| `rclone-crypt`             | `storagebox password`, `storagebox password2`, `gdrive password`, `gdrive password2` | The four obscured crypt passwords. Placeholders for now — they are minted after step 3                                       |

Two NetBird PATs, not one — and both on a **service user**, created in the dashboard before
either. A PAT tied to a person dies with that person's membership and takes both planes with it.
NetBird PATs cannot be scoped, so the split buys nothing in privilege: it means one can be
rotated without taking the other plane down.
They expire, at most a year out — see [Checks](checks.md#netbird-token-expiry).

One `healthchecks` item holds every node's ping URL, one field per node named for the host, so
adding a node is adding a field. Create each check in healthchecks.io first — period 2 minutes,
grace 15 minutes, which is past the ladder's restart and re-up rungs and short of its reboot rung.
A node whose field is missing still runs its watchdog; it just reports nothing.

Create the account itself first, and delete its shipped `Default` policy — the full sequence is
[Bootstrap](../tofu/netbird.md#bootstrap). Leave that policy in place and the rules you apply at
step 8 describe an access model nothing is enforcing.

`storagebox` and `rclone-crypt` are the items in the table no committed `pass://` reference
points at. Their consumers read Infisical, not the vault, so these copies exist only so the
credentials are recoverable — you retype them into `/infra/csi-rclone`. For the crypt passwords
that is not a convenience: lose one and the data it wrapped is ciphertext forever.

Three Infisical identities, not one, for the same reason — and a sharper one: `cluster-reader` is
seeded into the cluster, `tofu-writer` never leaves this machine. Collapsing them would hand the
cluster a write credential. `backup-reader` is split off for a different reason again: the cluster's
read credential must not also be the one that decrypts B2.

**The admin SSH private key goes in no store at all.** Ansible authenticates with your own
`~/.ssh` identity rather than reading it; only its public half is committed, SOPS-encrypted, at
step 4.

Finally, seal the reference map that points at all of this:

```bash
just ops sops config/secrets.sops.yaml
```

The template is already filled in — the paths above are exactly what it contains — so unless you
named the vault something other than `futharkd`, this is a save-and-encrypt with no edits. It is
sealed to your GPG key only, never the cluster age key; the reasoning is in
[Secrets](../conventions/secrets.md#why-the-reference-map-is-encrypted).

## 2. Infisical

Sign up at **eu.infisical.com**. That is a separate data region, not a mirror of
`app.infisical.com` — an account on one is invisible to the other. Create a project `futhark`
with a `prod` environment.

Create three Universal Auth machine identities. With yourself that is 4 of the 5 the free tier
allows:

- **`cluster-reader`** — read-only on the whole project, **denied** `/infra/velero`. Leave
  `accessTokenTrustedIps` alone for now; you set it at step 12, once the cluster has an egress
  address.
- **`tofu-writer`** — write on `/nodes/kenaz/actual` only.
- **`backup-reader`** — read on `/infra/velero` and nothing else. The split is deliberate: losing
  the cluster's read credential must not also mean losing the ability to decrypt B2. See
  [Secrets](../conventions/secrets.md).

Copy all three client ID/secret pairs into Proton Pass per the table above.

Then create the folders and secrets. Names are `SCREAMING_SNAKE_CASE` throughout, per
[Naming](../conventions/secrets.md#naming):

| Folder                | Secrets                                                                        | Consumed by                                                                    |
| --------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `/infra/cert-manager` | `BUNNY_API_KEY`                                                                | `infra/cert-manager/config/secret.yaml`                                        |
| `/infra/csi-rclone`   | `RCLONE_CONFIG`                                                                | `infra/storage/app/secret.yaml`                                                |
| `/infra/monitoring`   | `ADMIN_USER`, `ADMIN_PASSWORD`, `SLACK_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL`   | `infra/monitoring/app/grafana/secret.yaml`                                     |
| `/infra/auth`         | `POCKETID_ENCRYPTION_KEY`, `MAXMIND_LICENSE_KEY`                               | `infra/auth/app/infisicalsecret.yaml`                                          |
| `/infra/velero`       | `B2_KEY_ID`, `B2_APPLICATION_KEY`, `B2_SSE_C_KEY`, `KOPIA_REPOSITORY_PASSWORD` | `infra/backup/app/secret.yaml` and `secret-repo.yaml`, read as `backup-reader` |
| `/nodes/kenaz/actual` | none — leave empty                                                             | written by `just tf apply oidc`                                                |

`B2_KEY_ID` and `B2_APPLICATION_KEY` are placeholders for now: `tofu/b2` mints that key at step 8.
The other two are yours to generate — `B2_SSE_C_KEY` and `KOPIA_REPOSITORY_PASSWORD` both from
`openssl rand -base64 32`. Lose either and the backups are ciphertext forever, which is the whole
point of them; the durability table is in [Backup and recovery](recovery.md).

That table goes stale as apps are added. The authoritative version is the tree itself: every
`InfisicalStaticSecret` names its `secretPath`, and any that remaps a key names the Infisical
secret in its `template` block.

```bash
grep -rl 'kind: InfisicalStaticSecret' infra nodes
```

No NetBird credential appears in that table, and none should: nothing inside the cluster talks
to NetBird. Both PATs stay on the operator machine. `POCKETID_ENCRYPTION_KEY` is new material:
`openssl rand -base64 32`.
`RCLONE_CONFIG` is the one entry in that table you cannot fill in yet. It is assembled by hand
from `rclone` output, and `rclone` arrives with `just ops setup` at step 3 — so create the folder
now, leave the secret empty, and come back after that step. It also needs a Hetzner Storage Box
and a Google OAuth client that nothing else in this bootstrap creates.
[The rclone remotes](rclone.md) is the whole procedure, end to end.

## 3. The operator machine

`just` runs everything else here, so it has to come first — nothing can install its own runner:

```bash
sudo dnf install just
just ops setup
```

Installs `ansible-core`, `ansible-lint`, `yamllint`, `kubectl`, `helm`, `kustomize`, `k0sctl`,
`flux`, `rclone`, `tofu`, `pre-commit`, `sops`, `age`, `pass-cli`, the GPG smartcard stack, and
`mdbook` with `d2`/`mdbook-d2` for the diagrams;
installs the pre-commit hooks; runs `tofu init` in every module; and checks you have a Proton
Pass session. It needs `dnf` and `uv`.

`rclone` is the one there purely for bootstrap: nothing in `just` calls it, and it exists so you
can go back and finish [The rclone remotes](rclone.md) from step 2.

You need three things of your own: the GPG smartcard plugged in, the Proton Pass session from
step 1, and your own membership of the mesh — `k0s_cluster` resolves each node's mesh address
through NetBird's DNS from this machine.

Then generate the cluster age key:

```bash
just ops age-key
```

Put the printed `age1…` recipient into `.sops.yaml`, replacing
`AGE_CLUSTER_RECIPIENT_PLACEHOLDER`. Store the private key in Proton Pass as the `age key` field
of the `sops` item, then shred the temporary file. Why this key is separate from your GPG
key, and what it can and cannot open, is in [Secrets](../conventions/secrets.md#sops).

## 4. Node definitions

One `ansible/nodes/<hostname>/host.yml` per machine plus its encrypted `host.sops.yml`, both
symlinked into `ansible/inventory/host_vars/<hostname>/`, and the hostname listed in
`ansible/inventory/hosts.yml`. The schema and exact commands are in
[Nodes](../ansible/nodes.md#adding-a-node).

## 5. The encrypted files

Every `*.sops.*` file ships as a `.example` template. Ask which are still missing, then work
through them:

```bash
just ops sops                    # lists what has no real file yet
just ops sops <file>   # copies the template, opens it, encrypts on save
```

Re-run the same command later to edit one; it decrypts and re-encrypts around your editor. It
fails closed — an aborted edit or a failed encrypt removes the plaintext rather than leaving it
at a `*.sops.*` path.

What goes in each. The three under `tofu/` each carry two kinds of line — identifying values,
and the `pass://` references `pass-cli run` resolves at plan time — and both templates arrive
with the references already written, so only the identifying half needs filling in:

- `config/secrets.sops.yaml` — done at step 1, and nothing to fill in beyond the vault name.
- `ansible/inventory/group_vars/all/secrets.sops.yml` — `admin.user` and `admin.ssh_pubkey`.
- `ansible/nodes/<hostname>/host.sops.yml` — that node's public address. Leave `node_mesh_ip`
  out: the node has not joined the mesh yet, and `roles/netbird` writes it in at step 7.
- `infra/substitutions/app/edge-ips.sops.yaml` — the edge node's public and mesh addresses. **Put
  a placeholder in `MESH_IP` for now**; the node has not joined the mesh yet. Step 7 fills it.
- `config/dns/dns.sops.yaml` — the base domain and its subdomain labels. Flux, all three tofu
  modules and Ansible read this one file; nothing else spells a domain out. See
  [Domains](../conventions/domains.md).
- `tofu/netbird/secrets.sops.env` — its PAT only.
- `tofu/bunny/secrets.sops.env` — its API key only.
- `tofu/oidc/secrets.sops.env` — the Pocket ID base URL and the Infisical project ID.

None of the three `tofu/` files carries a node address or a domain: each module declares those
in its `refs.env` and reads them from the plane that owns them, at plan/apply time. See [Values another plane owns](../tofu/index.md#values-another-plane-owns).

Nothing builds until `config/dns/dns.sops.yaml` and `infra/substitutions/app/edge-ips.sops.yaml`
exist: both are referenced by a `kustomization.yaml`, so `kustomize build` fails without them. That is deliberate — better a
loud failure than a cluster reconciling with half its inputs missing.

## 6. Verify and push

```bash
pre-commit run --all-files
```

Everything must pass, including `kustomize build` and `sops-encrypted`. The latter is the one
that catches a plaintext committed by mistake; `gitleaks` will not, because a node address
matches no credential pattern.

Then commit and **push**. Flux reconciles from the remote, not from your working tree — an
unpushed commit is invisible to the cluster.

## 7. Host provisioning

```bash
just ans setup
```

Update, admin user, SSH hardening, mesh join, firewall. Add `<host>` to limit it to one
machine. Safe to re-run; `ssh_identity` picks whichever login currently answers. After the first
run each host answers only as the admin user on the hardened port. Provisioning nodes one at a
time is fine — the mesh-peer resolution in `roles/netbird` retries while the new peer's DNS
record propagates.

Each host's mesh address is read back out of `netbird status --json` and written into
`ansible/nodes/<hostname>/host.sops.yml` as `node_mesh_ip` by the same run, so `just ans setup`
leaves those files modified. Commit them — `playbooks/k0s.yml` reads the value from there, and
`tofu/bunny` gets the public address from the same file.

The `edge-ips` Secret is sealed to the cluster age key as well as yours, so it cannot share that
file and still needs filling by hand:

```bash
ssh <edge host> netbird status --json | jq -r .netbirdIp
sops infra/substitutions/app/edge-ips.sops.yaml     # set MESH_IP
git commit -am 'fix(edge-ips): real mesh address' && git push
```

## 8. Mesh policy, and the backup bucket

Both before the cluster, not after. Cross-node pod networking needs the all-protocol
node-to-node rule, and without it the cluster fails in ways that look like anything but a
network fault.

```bash
just tf init netbird
just tf plan netbird && just tf apply netbird
```

Read [netbird](../tofu/netbird.md) first. Two things this step cannot check for you: the
account's shipped `Default` policy has to be gone (step 1), and nothing validates a policy
server-side — NetBird has no policy tests, so a wrong rule applies cleanly and fails later, in
traffic.

This also sets the account's peer DNS domain and network range, so do it before any node joins:
a peer registered under the old ones has to re-register. The DNS zone it creates resolves
`*.$SUB_INTERNAL.$DOMAIN` to `traefik-internal`'s ClusterIP, which does not exist yet. That is
fine and stays fine: the record is static, the Service address is pinned in
`infra/traefik-internal/app/helmrelease.yaml`, and the name starts answering usefully once step
9 brings the workload up.

Then the bucket Velero backs up to, and the key it uses:

```bash
just tf init b2
just tf plan b2 && just tf apply b2
```

Read [b2](../tofu/b2.md) first — it needs a state bucket and an SSE-C key created by hand, and if a
bucket already exists it has to be imported rather than created. File the two outputs into
Infisical `/infra/velero` as `B2_KEY_ID` and `B2_APPLICATION_KEY`, replacing the placeholders from
step 2. Before the cluster because `infra/backup` reconciles at step 9 and reads them there; get it
wrong and the symptom is a `BackupStorageLocation` stuck `Unavailable` with the daily `Schedule`
still reading green.

## 9. Cluster and Flux

```bash
just ans k0s
```

Renders `k0sctl.yaml` from inventory, converges the cluster, installs the `local-path`
StorageClass, then bootstraps Flux — including the four Secrets that cannot come from Flux,
because Flux needs them to resolve anything else. The full sequence is in
[Bootstrap and reconciliation](../gitops/flux.md#bootstrap-sequence).

The kubeconfig lands at `ansible/.generated/kubeconfig`, mode 0600, gitignored. Every `ks:*`
and every `fx` recipe points at it automatically.

```bash
just ks status
just fx failing
```

Expect several minutes. Certificate issuance in particular waits on DNS-01 propagation. Anything
still failing after that, start at [Troubleshooting](troubleshooting.md).

## 10. The cloud plane

Pocket ID is running now, so create its admin API key at Settings → Admin → API Keys on
`auth.$DOMAIN`, and replace the `POCKETID_API_TOKEN` placeholder from step 1.

`tofu/oidc` writes into Infisical at the path the cluster is already watching, which is why it
goes last.

```bash
just tf plan bunny && just tf apply bunny
just tf plan oidc  && just tf apply oidc
```

Each has its own prerequisites — see [bunny](../tofu/bunny.md) and [oidc](../tofu/oidc.md).

## 11. Prove the isolation holds

The tier boundary is enforced by RBAC and an admission policy rather than by a secret store's
own namespaces, so it is worth confirming rather than assuming. Both checks are in
[Checks and CI](checks.md#infisical-tier-isolation). The admission one is the important half: an
`InfisicalStaticSecret` in a node namespace asking for an `/infra` path must be **rejected at
admission**, not merely fail to sync.

## 12. Aftercare

Set `accessTokenTrustedIps` on the `cluster-reader` identity to the cluster's egress address.
It is the only server-side constraint available on a single shared credential —
[Secrets](../conventions/secrets.md#infisical-and-how-tier-isolation-is-enforced) explains why
there is only one.

Then decommission whatever store these values came from, and confirm nothing still points at it:

```bash
grep -rn 'pass://' --exclude-dir=.git .
```
