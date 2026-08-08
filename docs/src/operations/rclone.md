# The rclone remotes

Assemble `RCLONE_CONFIG` and put it into Infisical `/infra/csi-rclone`, so the two rclone-backed
StorageClasses provision and mount. At the end, a PVC against each class binds and a pod mounts
it.

`RCLONE_CONFIG` is the only Infisical secret in [Cold bootstrap](setup.md) that is not generated
by a recipe or copied from a provider's console. You assemble it by hand on the operator machine
and paste the result in.

## Prerequisites

- `rclone` on the operator machine. `just ops setup` installs it at bootstrap step 3.
- A Hetzner account, for the Storage Box.
- A Google account and a GCP project you can create an OAuth client in.
- Access to write Infisical `/infra/csi-rclone`, and to the Proton Pass `futharkd` vault.

Expect an hour, most of it in two web consoles.

## The artifact

One INI with four sections: a backend, and a `crypt` wrapping it, for each of the two
StorageClasses in `infra/storage/app/`. Only the crypt section headers are fixed. Each must match
the `remote:` parameter of the class naming it (`storageclass-storagebox.yaml`,
`storageclass-gdrive.yaml`), or that class provisions nothing. The backend names underneath are
yours, as long as each crypt's `remote =` points at one.

```ini
[storagebox]
type = sftp
host = uXXXXX.your-storagebox.de
user = uXXXXX
port = 23
key_pem = -----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----\n

[storagebox-crypt]
type = crypt
remote = storagebox:
password = <obscured>
password2 = <obscured>

[gdrive]
type = drive
client_id = <your own>
client_secret = <your own>
scope = drive.file
root_folder_id = <the id rclone reports>
token = {"access_token":"…","refresh_token":"…","expiry":"…"}

[gdrive-crypt]
type = crypt
remote = gdrive:
password = <obscured>
password2 = <obscured>
```

Placeholders above: `uXXXXX` is your Storage Box subaccount and host, `<your own>` are the OAuth
client credentials from the Google console, and `<obscured>` are the four values
`rclone obscure` produces.

`rclone config` writes the two backend sections for you and gets one of them wrong for this
cluster. The crypt sections it never writes at all. Both are covered below.

## The Storage Box

Everything here is in the [Hetzner Console](https://console.hetzner.com), under **Storage Boxes**.

1. **Create Storage Box.** Pick a location and a size.

2. **Enable SSH support and External Reachability** in the box's settings. Port 22 is always
   active but carries SCP and SFTP only; port 23 is the one you enable, and it is the port rclone
   uses. External Reachability is not optional here, because the cluster is not inside Hetzner's
   network. Both settings take a few minutes to apply.

3. **Create a subaccount** for the cluster, so the credential the cluster holds is not the box's
   main account. Its username is the `user` in the INI, and it gets its own home directory.

4. **Generate a dedicated key pair.** Not your admin identity. This one ends up in Infisical and
   in every node's driver container.

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/futhark-storagebox -N '' -C futhark-csi
   ```

5. **Install the public half.** One command, and it handles both ports:

   ```bash
   cat ~/.ssh/futhark-storagebox.pub | ssh -p23 uXXXXX@uXXXXX.your-storagebox.de install-ssh-key
   ```

   The manual path is fiddlier than it looks, which is why `install-ssh-key` is the one to use:
   port 23 accepts only one-line OpenSSH keys and port 22 only RFC4716, so hand-uploading an
   `authorized_keys` means converting the key for whichever port you skipped.

6. **Check it.** No password prompt:

   ```bash
   sftp -P 23 -i ~/.ssh/futhark-storagebox uXXXXX@uXXXXX.your-storagebox.de
   ```

7. **Run `rclone config`.** `n` for a new remote, name it `storagebox`, storage type `sftp`, then
   the host, the subaccount username, port `23`, no password (the key replaces it), and
   `~/.ssh/futhark-storagebox` as the key file. Decline the advanced config and confirm.

8. **Replace `key_file` with `key_pem`.** The line rclone just wrote is a filesystem path. The
   CSI driver mounts the config Secret and nothing else, so that path does not exist inside the
   driver container and every mount fails at authentication. Inline the key instead:

   ```bash
   awk '{printf "%s\\n", $0}' < ~/.ssh/futhark-storagebox
   ```

   Paste that single line as `key_pem =` and delete the `key_file` line. (`key_pem` wins if both
   are present, but leaving a dead path in the config is how the next person gets confused.)

One option you may need and should not set pre-emptively. Port 23 gives a restricted shell, and
rclone probes it for a hash command on first use. **Whether that probe succeeds against a Storage
Box is unverified here.** If a mount logs errors about `md5sum`, set `disable_hashcheck = true` in
`[storagebox]`. Crypt does not use the remote's hashes anyway.

## The Google Drive credential

`[gdrive]` needs its own GCP project and OAuth client. rclone's built-in client ID is shared,
heavily rate limited, and being retired during 2026.

Two settings on that client decide whether the mount survives:

- **Publishing status must be `In production`.** An external app left in `Testing` is issued
  refresh tokens that expire after **7 days**. The CSI driver mounts the config Secret read-only,
  so rclone cannot write a rotated token back. A stable refresh token is a hard requirement, and
  the failure is silent until the eighth day. See
  [what cannot be rotated](rotation.md#what-cannot-be-rotated).
- **Scope `drive.file`, not `drive`.** It grants access only to files the app itself created,
  which is the folder boundary the cluster is supposed to have, enforced by Google rather than by
  convention. It is also not a sensitive scope, so publishing needs no verification review.
  `drive` is restricted and triggers one.

A personal Google account rules out a service account, which is the usual answer for unattended
access: a service account has no Drive quota of its own, and files it creates in a shared folder
fail. So this is a user OAuth token, minted once, interactively.

### In the Google Cloud console

The pages moved. What used to be "APIs & Services → OAuth consent screen" is now **Google Auth
Platform**, split across Branding, Audience, Data Access and Clients. Instructions written
against the old UI, including rclone's own, no longer match.

1. At [console.cloud.google.com](https://console.cloud.google.com), create a project. It exists
   only to hold this client.
2. **APIs & Services → Enable APIs and services**, search for **Google Drive API**, enable it.
   Without this the token mints fine and every call 403s.
3. **Google Auth Platform → Get started.** Fill in Branding (an app name and a support email),
   then set the audience to **External** and give a contact email.
4. **Data Access → Add or remove scopes.** Add `https://www.googleapis.com/auth/drive.file` and
   nothing else. rclone's own documentation tells you to add `drive`, `docs` and
   `drive.metadata.readonly`. Do not. `drive` is restricted, and asking for it puts the app into
   a verification review it will not pass for personal use.
5. **Audience → Add users.** Add yourself. You need to be a test user to authorize before the app
   is published.
6. **Clients → Create client.** Application type **Desktop app**, even though the operator machine
   may be headless. The headless flow below still uses a desktop client. Record the client ID and
   secret.
7. **Audience → Publish app.** Confirm the status now reads `In production`. This is the step
   whose omission is invisible for a week.

### Minting the token

Run `rclone config` again: `n`, name it `gdrive`, storage type `drive`, then the client ID and
secret from step 6. At the scope prompt, answer `drive.file` by value rather than by menu number,
because the numbering shifts between rclone versions. Leave `service_account_file` blank. Say **yes** to
the advanced config so you can reach `root_folder_id`, but leave it blank on this pass; you do not
have the id yet. Answer `n` to the Shared Drive question.

Then the browser. On a machine with one, take the default and let rclone open it. Headless, answer
`n` to "Use web browser to automatically authenticate rclone with remote?", run the
`rclone authorize "drive" "…"` command it prints on a machine that has a browser, and paste the
token back. Either way Google shows an unverified-app warning. That is expected for a personal
client, and you continue past it.

### The folder

With `drive.file`, rclone sees only what rclone created. A folder made in the Drive web UI is
invisible to the cluster no matter what you name it, so create it here:

```bash
rclone mkdir gdrive:futhark
rclone lsf --dirs-only --format pi --separator ' ' gdrive:
```

That id is `root_folder_id`. Set it with `rclone config`, editing the `gdrive` remote under
advanced config, or by hand in the file. Every path is then relative to that folder,
which is what puts the CSI driver's `<namespace>/<pvc>` inside it rather than at the root of your
Drive.

## The crypt sections and assembly

The two `crypt` sections are four lines each and no command writes them. Their `password` and
`password2` are **not plaintext**. rclone stores them obscured, and a plaintext value there fails
at mount time on the base64 decode rather than being read as the password. Generate each with:

```bash
rclone obscure "$(openssl rand -base64 32)"
```

Four values, all distinct. The two crypts do not share a password, so a leak of one does not read
the other's data. **Copy all four into the Proton Pass vault** before they go into Infisical, for
the same reason as Velero's encryption keys in [Backup and recovery](recovery.md#encryption): lose
one and its data is ciphertext forever, and Infisical is not a backup of itself. These are among
the values that [cannot be rotated](rotation.md#what-cannot-be-rotated).

`rclone config file` prints where rclone wrote the two backend sections. Add the crypt sections to
that file, check it against the INI at the top of this page, then paste the whole thing into
Infisical as `RCLONE_CONFIG` under `/infra/csi-rclone`.

Then destroy the local copy. It holds the Drive refresh token and the Storage Box private key in
the clear, and nothing on the operator machine reads it again:

```bash
shred -u "$(rclone config file | tail -1)" ~/.ssh/futhark-storagebox
```

Keep `~/.ssh/futhark-storagebox.pub` if you want to recognise the key on the box later; the
private half now lives only in Infisical and Proton Pass.

## Checking it worked

Before the config leaves the operator machine, both crypts must resolve. An empty listing is a
pass, an error is not:

```bash
rclone lsd storagebox-crypt:
rclone lsd gdrive-crypt:
```

After Infisical has it, confirm the operator synced it through and that what landed is the INI you
pasted:

```bash
kubectl -n csi-rclone get secret storagebox-secret -o jsonpath='{.data.configData}' | base64 -d
```

The end-to-end test is a PVC. Create one against each class, watch it bind, and delete it:

```bash
kubectl -n default create -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rclone-smoke
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: storagebox-crypt
  resources:
    requests:
      storage: 1Gi
EOF
kubectl -n default get pvc rclone-smoke -w
```

Binding proves provisioning, not mounting. The mount happens when a pod attaches. If a pod stays
in `ContainerCreating`, the reason is in the node driver's rclone container:

```bash
kubectl -n csi-rclone get pods -o wide
kubectl -n csi-rclone logs <the node pod on the pod's node> -c rclone --tail=50
```

The node DaemonSet is what mounts, so the pod you want is the one on the same node as the stuck
workload. That is what `-o wide` is for.

Both classes are `reclaimPolicy: Retain`, so deleting the PVC leaves the directory on the remote.
Remove it with `rclone purge` if you do not want the smoke test's leftovers.
