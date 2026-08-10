# Credential rotation

Replace any credential this repository depends on, prove the replacement works, then retire the
old value. Each section below is self-contained: read the one you need.

The reader this page assumes is an operator with a Proton Pass session and a GPG smartcard, part
way through an incident or a scheduled rotation, who wants to know what breaks, what to run, and
how to tell it worked.

## Prerequisites

- A Proton Pass session on this machine. `pass-cli info` must succeed. If it does not, see
  [Secrets](../conventions/secrets.md#proton-pass).
- The GPG smartcard, for anything that re-encrypts a `*.sops.*` file.
- `kubectl` pointed at the cluster, for anything that reseeds a Secret. Every `just ks` and
  `just fx` recipe sets `KUBECONFIG` itself.

## The rule that makes most of this cheap

Nothing in git holds a credential. Committed files hold `pass://<vault>/<item>/<field>`
references, and `pass-cli` resolves them at run time. Update a Proton Pass item **in place** and
every reference keeps resolving, so most rotations need no commit at all.

Two families of exception, and both are called out in their own sections below:

- Values sealed into a `*.sops.*` file rather than referenced, such as `admin.ssh_pubkey`.
- Values consumed from Infisical by the cluster rather than from Proton Pass by the operator.
  Proton Pass holds a copy for recovery, so both stores move.

## Order of operations

Every procedure here follows the same shape, and the order is what makes it safe:

1. Create the new credential. The old one stays live.
2. File the new value where its consumers read it.
3. Prove a consumer works with the new value.
4. Only then revoke or delete the old one.
5. Prove the same consumer still works after the revoke.

Step 5 is not ceremony. It is the only evidence that nothing else was quietly using the old
credential. `just bak backups` after a B2 key rotation is the worked example.

Because the old value stays live until step 4, rollback for steps 1 through 3 is always the same:
put the old value back where you got it and re-run the verification. After step 4 there is no
rollback, which is why the proof comes first.

## Standing schedule

| Credential                  | Cadence                               | Why                                                |
| --------------------------- | ------------------------------------- | -------------------------------------------------- |
| `netbird-enrollment` PAT    | Before expiry, 365 days at most       | NetBird caps PAT lifetime                          |
| `netbird-policy` PAT        | Before expiry, 365 days at most       | Same cap                                           |
| Velero's B2 application key | On a schedule of your choosing        | The only replaceable credential in the backup path |
| Everything else             | On suspicion, or operator offboarding | No expiry, no automatic trigger                    |

Expiry dates are not tracked anywhere in this repository. Put both NetBird dates in a calendar
when you issue the tokens. What breaks when each lapses is in
[Checks and CI](checks.md#netbird-token-expiry).

## Operator identity

### GPG key

The `.sops.yaml` recipient is the **primary** key's full fingerprint, so renewing or replacing the
encryption subkey alone changes no file. `gpg` selects the current encryption-capable subkey at
encrypt time. Rotate the subkey freely and stop here.

Replacing the primary key is the expensive case, because every encrypted file in the repository is
sealed to it.

**Blast radius:** none while both keys are recipients. Between removing the old recipient and
having the new key available on every operator machine, no `*.sops.*` file can be decrypted, which
blocks Ansible, OpenTofu and `just ops sops`. Flux is unaffected: it decrypts with the cluster age
key, which is a separate recipient.

1. Generate the new key and move its encryption subkey to the smartcard.
2. Add the new fingerprint alongside the old one under **every** `creation_rules` entry in
   `.sops.yaml`. All three rules name the same PGP recipient today.
3. Re-encrypt the data key of both files to both recipients:

   ```bash
   just ops rekey
   ```

   The recipe runs `sops updatekeys` over every `*.sops.*` file in the repository. It rewrites
   the recipient list only. It does not change any value, so the diff is confined to the SOPS
   metadata block.

4. Verify by decrypting the file matched by each `.sops.yaml` rule, using the new key:

   ```bash
   sops -d config/sops/ops.sops.yaml >/dev/null
   sops -d config/sops/cluster.sops.yaml >/dev/null
   ```

   Both must exit 0. A rule you forget in step 2 fails here, not later.

5. Remove the old fingerprint from `.sops.yaml`, run `just ops rekey` again, and repeat both
   decrypts.
6. Commit. The diff touches `.sops.yaml` and the metadata block of both encrypted files.
7. Revoke the old key and publish the revocation.

**Rollback:** until step 5, the old key is still a recipient and still decrypts everything. After
step 5, restore the previous commit and re-run `updatekeys` while you still hold the old key.

### Proton Pass personal access token

**Blast radius:** `pass-cli` stops resolving references, so `just ans render-secrets`,
`just ans setup`, `just ans k8s` and every `just tf` recipe fail. The cluster is unaffected. It
holds no Proton Pass credential, by design.

1. Mint a new personal access token in the Proton Pass web app.
2. Log in with it:

   ```bash
   PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_… pass-cli login
   pass-cli info
   ```

   Replace `pst_…` with the new token. `pass-cli` persists a session after this, so it is a
   once-per-machine step.

3. Verify a real resolution rather than the session alone:

   ```bash
   just ans render-secrets
   ```

   It writes `ansible/.generated/secrets.yml`. No `pass://` string may survive in it:

   ```bash
   grep -c 'pass://' ansible/.generated/secrets.yml    # expect 0
   ```

4. Revoke the old token in the web app.

Do this on every operator machine. The session is per machine.

### Admin SSH key

This key is in no store. It is your own identity in `~/.ssh`, and Ansible authenticates with it
rather than reading it. Only the public half is committed, as `ansible.admin.ssh_pubkey` in
`config/sops/ops.sops.yaml`.

**Blast radius:** this is the path back into a node. Getting it wrong locks you out of every host
at once.

1. Generate the new keypair and load it into your agent.
2. Add the new public key **alongside** the old one. `admin.ssh_pubkey` holds a single value
   today, so the safest sequence is to append the new key to the admin user's
   `~/.ssh/authorized_keys` on each host by hand first:

   ```bash
   ssh-copy-id -i ~/.ssh/<new key>.pub -p <hardened port> <admin user>@<host>
   ```

3. Verify you can log in with the new key on every host before touching anything else.
4. Set `admin.ssh_pubkey` to the new key and re-encrypt:

   ```bash
   just ops sops config/sops/ops.sops.yaml
   ```

5. Apply it, which rewrites `authorized_keys` and drops the old key:

   ```bash
   just ans setup
   ```

6. Verify a fresh connection on each host, in a **new** terminal, keeping the working session
   open until it succeeds.
7. Delete the old private key locally.

**Rollback:** while the session from step 6 is still open, put the old public key back in the SOPS
file and re-run `just ans setup`.

## Proton Pass, the crown-jewel vault

The item and field names are in the table at
[Cold bootstrap](setup.md#1-proton-pass). Rotation updates the item in place, so the committed
`pass://` references do not change.

### The cluster age key

Flux mounts this as `flux-system/sops-age` and it is the only key that opens the cluster-plane
files. It cannot open anything under `ansible/` or `tofu/`.

**Blast radius:** every Flux Kustomization with `spec.decryption` fails to decrypt, so nothing
reconciles. Running workloads keep running.

1. Generate the new keypair:

   ```bash
   just ops age-key
   ```

   It prints the `age1…` public recipient and the path to a temporary private key file.

2. Add the new recipient **alongside** the old one on the `config/sops/cluster.sops.yaml` rule in
   `.sops.yaml`, then re-encrypt that file to both:

   ```bash
   just ops rekey
   ```

3. Store the new private key in the `age key` field of the `sops` item, then shred the temporary
   file. Keep a copy of the old key until step 6.
4. Reseed the cluster:

   ```bash
   just ans k8s
   ```

   `ansible/roles/flux_bootstrap` recreates `flux-system/sops-age`.

5. Verify Flux decrypts with it:

   ```bash
   just fx failing
   ```

   Empty output. A decryption failure surfaces on the Kustomization, not the HelmRelease, so also
   check `just fx get` shows every Kustomization `Ready`.

6. Remove the old recipient from `.sops.yaml`, re-run `just ops rekey` from step 2, commit,
   push, and confirm `just fx failing` is still empty after Flux has pulled the new commit.

**Rollback:** before step 6 the old key is still a recipient. Restore the previous
`flux-system/sops-age` by putting the old private key back in Proton Pass and re-running
`just ans k8s`.

### The Flux deploy key

**Blast radius:** Flux cannot fetch the repository. Running workloads keep running, and nothing
new reconciles.

1. Generate a keypair:

   ```bash
   ssh-keygen -t ed25519 -f /tmp/flux-deploy -N '' -C futhark-flux
   ```

2. Add `/tmp/flux-deploy.pub` to the repository's Deploy Keys on GitHub. Read-only is enough.
   Leave the old deploy key in place.
3. Put the private half in the `deploy key` field of the `flux` item **base64-encoded on a single
   line**, then `shred -u /tmp/flux-deploy*`:

   ```bash
   base64 -w0 < /tmp/flux-deploy
   ```

   The field must hold that one line and nothing else. A multi-line private key is silently
   flattened on the way to the cluster, and step 5 then fails with `ssh: no key found` on the
   `GitRepository`. See [Multi-line values](../conventions/secrets.md#multi-line-values).

4. Reseed `flux-system/git-deploy-key`:

   ```bash
   just ans k8s
   ```

5. Verify Flux fetches with it. Push a trivial commit, then:

   ```bash
   just fx reconcile
   just fx sources
   ```

   The `GitRepository` must report the new commit as `Ready`, with its revision matching what you
   just pushed.

6. Delete the old deploy key on GitHub, then repeat step 5. A fetch that still succeeds is the
   evidence nothing else was using it.

### The NetBird tokens

Two Personal Access Tokens, one per service user. Both expire, 365 days out at most. A PAT
inherits the role of the user it belongs to, so issue the replacement **on the same service user**
and no role changes.

**Blast radius:** neither takes the mesh down. Peers keep their configuration and keep connecting.
What stops is changing anything: no policy applies, and no new node joins. The full table of what
breaks is [Checks and CI](checks.md#netbird-token-expiry).

1. In the NetBird dashboard, **Team → Users**, open the service user, then **Access Tokens**.
2. Create a new token with the same name. The plaintext is shown once and stored hashed, so file
   it before closing the dialog.
3. Update the token field of the matching Proton Pass item in place.
4. Verify, and the check differs per token:

   `netbird-policy`, used by `tofu/netbird`:

   ```bash
   just tf plan netbird
   ```

   A clean plan. A dead token returns 401 rather than a plan.

   `netbird-enrollment`, used by `ansible/roles/netbird`:

   ```bash
   just ans setup <host>
   ```

   The task named "Mint a single-use setup key" must succeed. An already-connected peer skips both
   the lookup and the mint, so this only exercises the token on a peer that is not currently
   joined. If every peer is up, the honest check is to re-enrol one deliberately, or to accept that
   the token is unverified until the next join.

5. Delete the old token in the dashboard.

If a token was minted ad hoc for a one-off task, delete it as soon as the task is verified rather
than leaving it to expire. The elevation procedure in
[netbird](../tofu/netbird.md#applying-account-settings) is the case where this comes up.

### The Infisical machine identities

Three Universal Auth identities, each a client ID and client secret pair:
`infisical-cluster-reader`, `infisical-tofu-writer`, `infisical-backup-reader`. What each is
scoped to is [Cold bootstrap](setup.md#2-infisical).

**Blast radius:** `cluster-reader` and `backup-reader` are seeded into the cluster, so rotating
either stops every `InfisicalStaticSecret` in its tier from syncing. Existing Kubernetes Secrets
are not deleted, so running pods keep their values until they restart. `tofu-writer` never leaves
the operator machine and only affects `just tf apply oidc`.

1. In the Infisical console, add a new client secret to the identity. An identity can hold more
   than one, so the old secret stays valid.
2. Update the `client secret` field of the matching Proton Pass item in place.
3. For `cluster-reader` and `backup-reader`, reseed `infisical-universal-auth` into every tier
   namespace:

   ```bash
   just ans k8s
   ```

4. Verify. The observable condition is an `InfisicalStaticSecret` that resyncs:

   ```bash
   kubectl get infisicalstaticsecrets -A
   ```

   Every one must report ready. `InfisicalAuth is not ready` here means the seed Secret is
   missing or stale, not that the operator is broken. See
   [Secrets](../conventions/secrets.md#the-secrets-outside-gitops).

   For `tofu-writer`:

   ```bash
   just tf plan oidc
   ```

5. Delete the old client secret in the console, then repeat step 4.

Rotating the secret does not touch the identity's project membership, role, paths, or
`accessTokenTrustedIps`. Those live only in the console and are unaffected. If you replace the
whole **identity** rather than its secret, all four have to be set again, and a missing project
membership surfaces as `Unauthorized access: status 403`.

### The Bunny API key

Bunny keys are account-wide, not zone-scoped, and two consumers read this one: `tofu/bunny` from
Proton Pass, and cert-manager's DNS-01 webhook from Infisical `/infra/cert-manager` as
`BUNNY_API_KEY`. Both move together.

**Blast radius:** DNS records stop being managed and certificate issuance fails at the DNS-01
challenge. Existing certificates keep working until renewal.

1. Create the new key in the Bunny console.
2. Update the `api key` field of the `bunny` item in Proton Pass.
3. Update `BUNNY_API_KEY` under `/infra/cert-manager` in Infisical.
4. Verify both consumers. A clean plan proves the first:

   ```bash
   just tf plan bunny
   ```

   The second needs a real challenge, because the webhook only uses the key at issuance:

   ```bash
   just ks certs
   ```

   Delete one certificate's Secret to force a renewal and watch it reissue, or wait for a
   scheduled renewal. Until an issuance succeeds, the webhook half is unverified.

5. Revoke the old key.

### The Pocket ID API token

Used by `tofu/oidc` only.

**Blast radius:** `just tf apply oidc` fails. Existing OIDC clients keep working.

1. On `auth.$DOMAIN`, **Settings → Admin → API Keys**, create a key.
2. Update the `api token` field of the `pocketid` item.
3. Verify:

   ```bash
   just tf plan oidc
   ```

4. Delete the old key.

### The Backblaze keys

Three distinct credentials, and they are easy to confuse:

| Item                   | Used by                                                 | Rotation                                 |
| ---------------------- | ------------------------------------------------------- | ---------------------------------------- |
| `backblaze-tofu`       | `tofu/b2`'s provider                                    | Below                                    |
| `backblaze-tofu-state` | `tofu/b2`'s S3 state backend, plus its state passphrase | Below                                    |
| Velero's B2 key        | Velero, via Infisical `/infra/velero`                   | [Velero's B2 key](#veleros-b2-key) below |

For `backblaze-tofu`:

1. Create a new application key in the Backblaze console with the same capabilities.
2. Update `key id` and `application key` on the item.
3. Verify:

   ```bash
   just tf plan b2
   ```

4. Delete the old key.

For `backblaze-tofu-state`, the same loop applies to `key id` and `application key`, verified by
any `just tf plan b2`, which reads and locks the remote state.

The `state passphrase` field on that item is different. It derives the key OpenTofu encrypts the
state with, client-side. It rotates through the same fallback mechanism the migration off SSE-C
used: in `tofu/b2/backend.tf`, add a second `key_provider` holding the old passphrase, point the
`fallback` at a method keyed to it, run any `just tf plan b2` to read the old state and any `just
tf apply b2` to rewrite it under the new one, then delete the fallback. Verify by fetching the
object and confirming it is not JSON.

### The healthchecks.io ping URLs

One field per node on the `healthchecks` item, named for the host. The URL is the credential:
anyone holding it can ping the check.

**Blast radius:** that node's watchdog stops reporting. The node itself is unaffected, and the
check goes red after its grace period, which reads as a node fault and is not one.

1. In healthchecks.io, regenerate the check's ping URL.
2. Update the matching field on the `healthchecks` item.
3. Apply it to the node:

   ```bash
   just ans setup <host>
   ```

4. Verify the check reports within its 2 minute period and returns to green.

### The Storage Box SSH key

The private half is in the `storagebox` item and in `STORAGEBOX_KEY_PEM` in Infisical
`/infra/csi-rclone`, from where `infra/storage/app/secret.yaml` templates it in as `key_pem`,
escaping its newlines on the way. Both move together. Store the key file as it is; nothing about it
is reformatted by hand.

**Blast radius:** every `storagebox-crypt` mount fails at authentication. Pods with an existing
mount keep it until they are rescheduled.

1. Generate the new keypair and install the public half, which covers both ports:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/futhark-storagebox-new -N '' -C futhark-csi
   cat ~/.ssh/futhark-storagebox-new.pub | ssh -p23 uXXXXX-subN@uXXXXX-subN.your-storagebox.de install-ssh-key
   ```

2. Verify the new key on its own before changing anything:

   ```bash
   sftp -P 23 -i ~/.ssh/futhark-storagebox-new uXXXXX-subN@uXXXXX-subN.your-storagebox.de
   ```

3. Update `STORAGEBOX_KEY_PEM` under `/infra/csi-rclone` with the contents of
   `~/.ssh/futhark-storagebox-new`, verbatim, and the `ssh key` field of the `storagebox` item.
   Nothing else in the config changes, and no other credential is touched.
4. Confirm the operator synced the change through, and that `key_pem` came out as one line with
   `\n` between the key's lines:

   ```bash
   kubectl -n csi-rclone get secret storagebox-secret -o jsonpath='{.data.configData}' | base64 -d
   ```

5. Verify a real mount. Create a PVC against `storagebox-crypt` and attach a pod to it. Binding
   alone proves provisioning, not mounting. The procedure is in
   [The rclone remotes](rclone.md#checking-it-worked).
6. Remove the old public key from the subaccount's `authorized_keys`, then repeat step 5.

Why `key_pem` and not `key_file`: the CSI driver mounts the config Secret and nothing else, so a
filesystem path in the config does not exist inside the driver container.

## Infisical, per app

### Velero's B2 key

The only credential in the backup path that can be replaced at all. `tofu/b2` mints it.

**Blast radius:** backups stop. Nothing fails loudly, because a suspended or failing schedule is
not an error state on the `BackupStorageLocation` alone. The 26h "no backup succeeded" alert in
`infra/monitoring/app/grafana/alerting/backup.yaml` is what catches it.

Both `capabilities` and `bucket_ids` force replacement, so rotation is the create loop, forced:

1. Mint the replacement. **This destroys the old key first** — `b2_application_key.velero` has no
   `create_before_destroy`, so from here until step 3 lands no valid key exists and backups fail.
   There is no rollback past this point, because the old key is already gone:

   ```bash
   just tf apply b2 -replace=b2_application_key.velero
   ```

2. Read the two `sensitive` outputs:

   ```bash
   just tf output b2 -raw velero_b2_key_id           # -> B2_KEY_ID
   just tf output b2 -raw velero_b2_application_key  # -> B2_APPLICATION_KEY
   ```

3. File both into Infisical `/infra/velero`.
4. Verify with a real backup, not with a plan:

   ```bash
   just bak now
   just bak backups
   ```

   The new backup must reach `Completed`.

5. Confirm the old key is gone, rather than revoking it by hand — the apply in step 1 deleted it:

   ```bash
   b2 key list --long    # one `velero` entry, the new id from step 2
   ```

**No rollback.** The old key is destroyed in step 1, before anything has been verified. If step 4
fails you go forward, not back: re-read the outputs and re-file them. Giving the resource a
`create_before_destroy` lifecycle would make a rollback possible and close the outage window, at
the cost of two live keys mid-rotation.

### Everything else under `/infra` and `/nodes`

The generic loop for any per-app runtime secret, such as Grafana's `ADMIN_PASSWORD` or
`MAXMIND_LICENSE_KEY`:

1. Change the value at the provider, if it has one.
2. Update it in Infisical at its path.
3. Wait for the owning `InfisicalStaticSecret`'s `refreshInterval`, then confirm the Kubernetes
   Secret changed:

   ```bash
   kubectl -n <namespace> get secret <name> -o jsonpath='{.data.<KEY>}' | base64 -d
   ```

4. Restart the consumer if it reads its configuration only at startup:

   ```bash
   just ks restart <namespace> <deployment>
   ```

5. Verify the app works, then revoke the old value at the provider.

Which paths exist and who reads them is in [Cold bootstrap](setup.md#2-infisical). The
authoritative list is the tree:

```bash
grep -rl 'kind: InfisicalStaticSecret' infra nodes
```

## What cannot be rotated

Four values. Each one is unrotatable for a different reason, and in three cases the data is lost
with the key.

**`KOPIA_REPOSITORY_PASSWORD`.** Baked into the Kopia repository when Velero's node-agent first
initialises it, and unchangeable afterwards without starting a new repository. A new repository
means the existing backups stay readable only with the old password. See
[Backup and recovery](recovery.md#encryption).

**`B2_SSE_C_KEY`.** Backblaze stores the manifest tarballs as ciphertext it cannot read. Changing
the key orphans every tarball already written under the old one.

**The four `rclone-crypt` passwords.** `password` and `password2` on each crypt remote derive the
keys that wrapped the data. Change one and the data it wrapped is unreadable. They are stored
obscured rather than plaintext, so treat the obscured string as the value.

**The Google Drive OAuth refresh token.** Rotatable at Google, but the cluster cannot accept a
rotated one: the CSI driver mounts the config Secret read-only, so rclone cannot write a refreshed
token back. A stable refresh token is a hard requirement, which is why the OAuth client must stay
at publishing status `In production`. Left in `Testing`, Google issues tokens that expire after 7
days and the mount fails silently on the eighth. See
[The rclone remotes](rclone.md#the-google-drive-credential).

Losing any of the first three loses the data it protects, with no recovery path. That is the same
property that keeps the provider from reading it. Both backup keys have a copy in Proton Pass for
exactly this reason, and that copy is the one deliberate duplication in the secrets scheme.

## Operator offboarding

Rotate in this order, so no step locks you out of the next one:

1. Every Proton Pass item the person could read, using the procedures above.
2. The Flux deploy key.
3. The cluster age key.
4. The admin SSH key.
5. The GPG primary key, last, because every other step needs a working `sops`.
6. Remove the person's Proton Pass vault access and their NetBird peers from the `admin` group.

Confirm nothing still points at a decommissioned store:

```bash
grep -rn 'pass://' --exclude-dir=.git .
```
