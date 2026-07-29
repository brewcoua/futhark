# Cold bootstrap

Building the whole thing from nothing, in order. Every step is re-runnable.

Two values cannot exist until something else is running, so they are filled in twice: the edge
node's mesh address (step 7) and the Pocket ID API token (step 10). Both are called out where
they land.

```d2
direction: down

stores: "1-2. The remote stores\nProton Pass vault, Infisical identities and folders"
repo: "3-6. This machine and this repo\nops:setup, age key, node definitions,\nthe encrypted files, push"
hosts: "7-8. The hosts and the tailnet\nans:setup, then tf:apply -- tailscale"
cluster: "9. The cluster\nans:k0s — k0sctl, local-path, Flux"
cloud: "10. The cloud plane\ntf:apply -- bunny, oidc"
after: "11-12. Prove the isolation,\nthen accessTokenTrustedIps"

stores -> repo -> hosts -> cluster -> cloud -> after

hosts -> repo: "MESH_IP was a placeholder in step 5 —\nthe node had not joined the tailnet yet" {
  style: { stroke-dash: 4; stroke: "#c00" }
}
cloud -> stores: "POCKETID_API_TOKEN was a placeholder in step 1 —\nPocket ID did not exist yet" {
  style: { stroke-dash: 4; stroke: "#c00" }
}
```

The two red edges are the only backward ones, and they are why the phases are not simply a
list: both values are produced by a step that needs a file written several steps earlier.

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

| Item                       | Fields                       | Value                                                                                                                        |
| -------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `flux`                     | `deploy key`                 | The private half generated above                                                                                             |
| `sops`                     | `age key`                    | Generated at step 3                                                                                                          |
| `bunny`                    | `api key`                    | Bunny account API key. Same permissions as cert-manager's DNS-01 webhook uses — Bunny keys are account-wide, not zone-scoped |
| `pocketid`                 | `api token`                  | Placeholder for now — Pocket ID does not exist yet. Filled in at step 10                                                     |
| `tailscale-authkey`        | `client id`, `client secret` | OAuth client scoped to **auth-key creation**                                                                                 |
| `tailscale-policy`         | `client id`, `client secret` | A **second** OAuth client, with **write on the policy file**                                                                 |
| `infisical-cluster-reader` | `client id`, `client secret` | The `cluster-reader` identity from step 2                                                                                    |
| `infisical-tofu-writer`    | `client id`, `client secret` | The `tofu-writer` identity from step 2                                                                                       |

Two Tailscale OAuth clients, not one: `ansible/roles/tailscale` mints single-use node auth keys,
`tofu/tailscale` rewrites the policy file. Neither needs the other's scope.

Two Infisical identities, not one, for the same reason — and a sharper one: `cluster-reader` is
seeded into the cluster, `tofu-writer` never leaves this machine. Collapsing them would hand the
cluster a write credential.

**The admin SSH private key goes in no store at all.** Ansible authenticates with your own
`~/.ssh` identity rather than reading it; only its public half is committed, SOPS-encrypted, at
step 4.

Finally, seal the reference map that points at all of this:

```bash
task ops:sops -- config/secrets.sops.yaml
```

The template is already filled in — the paths above are exactly what it contains — so unless you
named the vault something other than `futharkd`, this is a save-and-encrypt with no edits. It is
sealed to your GPG key only, never the cluster age key; the reasoning is in
[Secrets](../conventions/secrets.md#why-the-reference-map-is-encrypted).

## 2. Infisical

Sign up at **eu.infisical.com**. That is a separate data region, not a mirror of
`app.infisical.com` — an account on one is invisible to the other. Create a project `futhark`
with a `prod` environment.

Create two Universal Auth machine identities. With yourself that is 3 of the 5 the free tier
allows:

- **`cluster-reader`** — read-only on the whole project. Leave `accessTokenTrustedIps` alone for
  now; you set it at step 12, once the cluster has an egress address.
- **`tofu-writer`** — write on `/nodes/kenaz/actual` only.

Copy both client ID/secret pairs into Proton Pass per the table above.

Then create the folders and secrets. Names are `SCREAMING_SNAKE_CASE` throughout, per
[Naming](../conventions/secrets.md#naming):

| Folder                | Secrets                                                                      | Consumed by                                   |
| --------------------- | ---------------------------------------------------------------------------- | --------------------------------------------- |
| `/infra/cert-manager` | `BUNNY_API_KEY`                                                              | `infra/cert-manager/config/secret.yaml`       |
| `/infra/csi-rclone`   | `RCLONE_CONFIG`                                                              | `infra/storage/app/secret.yaml`               |
| `/infra/monitoring`   | `ADMIN_USER`, `ADMIN_PASSWORD`, `SLACK_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL` | `infra/monitoring/app/grafana/secret.yaml`    |
| `/infra/tailscale`    | `TAILSCALE_CLIENT_ID`, `TAILSCALE_CLIENT_SECRET`                             | `infra/tailscale-operator/config/secret.yaml` |
| `/infra/auth`         | `POCKETID_ENCRYPTION_KEY`, `MAXMIND_LICENSE_KEY`                             | `infra/auth/app/infisicalsecret.yaml`         |
| `/nodes/kenaz/actual` | none — leave empty                                                           | written by `task tf:apply -- oidc`            |

That table goes stale as apps are added. The authoritative version is the tree itself: every
`InfisicalStaticSecret` names its `secretPath`, and any that remaps a key names the Infisical
secret in its `template` block.

```bash
grep -rl 'kind: InfisicalStaticSecret' infra nodes
```

`TAILSCALE_CLIENT_ID`/`_SECRET` here are the **auth-key** OAuth client — the same credential as
the vault's `tailscale-authkey`, because the in-cluster operator and the Ansible role both mint
node keys. `POCKETID_ENCRYPTION_KEY` is new material: `openssl rand -base64 32`.
`RCLONE_CONFIG` is a full rclone INI whose crypt section header must be `[storagebox-crypt]`, to
match `remote:` in `infra/storage/app/storageclass.yaml`.

## 3. The operator machine

```bash
task ops:setup
```

Installs `ansible-core`, `ansible-lint`, `yamllint`, `kubectl`, `helm`, `kustomize`, `k0sctl`,
`flux`, `tofu`, `pre-commit`, `sops`, `age`, `pass-cli`, the GPG smartcard stack, and `mdbook`
with `d2`/`mdbook-d2` for the diagrams;
installs the pre-commit hooks; runs `tofu init` in every module; and checks you have a Proton
Pass session. It needs `dnf` and `uv`.

You need three things of your own: the GPG smartcard plugged in, the Proton Pass session from
step 1, and your own tailnet membership — `k0s_cluster` resolves each node's mesh address through
MagicDNS from this machine.

Then generate the cluster age key:

```bash
task ops:age-key
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
task ops:sops                    # lists what has no real file yet
task ops:sops -- <file>          # copies the template, opens it, encrypts on save
```

Re-run the same command later to edit one; it decrypts and re-encrypts around your editor. It
fails closed — an aborted edit or a failed encrypt removes the plaintext rather than leaving it
at a `*.sops.*` path.

What goes in each. The three under `tofu/` each carry two kinds of line — identifying values,
and the `pass://` references `pass-cli run` resolves at plan time — and both templates arrive
with the references already written, so only the identifying half needs filling in:

- `config/secrets.sops.yaml` — done at step 1, and nothing to fill in beyond the vault name.
- `ansible/inventory/group_vars/all/secrets.sops.yml` — `admin.user`, `admin.ssh_pubkey`,
  and `tailnet_domain`.
- `ansible/nodes/<hostname>/host.sops.yml` — that node's public address. Leave `node_mesh_ip`
  out: the node has not joined the tailnet yet, and `roles/tailscale` writes it in at step 7.
- `infra/substitutions/app/edge-ips.sops.yaml` — the edge node's public and mesh addresses. **Put
  a placeholder in `MESH_IP` for now**; the node has not joined the tailnet yet. Step 7 fills it.
- `infra/substitutions/app/int-domain.sops.yaml` — the internal base domain. `tofu/bunny` and
  `tofu/oidc` both read it from here, so this is its only copy.
- `tofu/tailscale/secrets.sops.env` — its OAuth client only.
- `tofu/bunny/secrets.sops.env` — its API key only.
- `tofu/oidc/secrets.sops.env` — the Pocket ID base URL and the Infisical project ID.

None of the three `tofu/` files carries a node address, a tailnet name or the internal domain:
each module declares those in its `refs.env` and reads them from the plane that owns them, at
plan/apply time. See [Values another plane owns](../tofu/index.md#values-another-plane-owns).

Nothing builds until the two under `infra/substitutions/` exist: both are referenced by a
`kustomization.yaml`, so `kustomize build` fails without them. That is deliberate — better a
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
task ans:setup
```

Update, admin user, SSH hardening, mesh join, firewall. Add `-- <host>` to limit it to one
machine. Safe to re-run; `ssh_identity` picks whichever login currently answers. After the first
run each host answers only as the admin user on the hardened port. Provisioning nodes one at a
time is fine — the mesh-peer resolution in `roles/tailscale` retries while MagicDNS catches up.

Each host's mesh address is read back with `tailscale ip -4` and written into
`ansible/nodes/<hostname>/host.sops.yml` as `node_mesh_ip` by the same run, so `task ans:setup`
leaves those files modified. Commit them — `playbooks/k0s.yml` reads the value from there, and
`tofu/bunny` gets the public address from the same file.

The `edge-ips` Secret is sealed to the cluster age key as well as yours, so it cannot share that
file and still needs filling by hand:

```bash
ssh <edge host> tailscale ip -4
sops infra/substitutions/app/edge-ips.sops.yaml     # set MESH_IP
git commit -am 'fix(edge-ips): real mesh address' && git push
```

## 8. Tailnet policy

Do this **before** the cluster, not after. Cross-node pod networking needs the `ip-in-ip` rule,
and without it the cluster fails in ways that look like anything but a network fault.

The first apply needs an import, because the resource owns the entire policy document — read
[tailscale](../tofu/tailscale.md#first-apply) in full first.

```bash
cd tofu/tailscale
sops exec-env secrets.sops.env 'pass-cli run -- tofu import tailscale_acl.this acl'
cd ../..
task tf:plan -- tailscale && task tf:apply -- tailscale
```

The policy tests only run on `apply` — a green `plan` is not evidence they pass, because plan
never submits the document.

## 9. Cluster and Flux

```bash
task ans:k0s
```

Renders `k0sctl.yaml` from inventory, converges the cluster, installs the `local-path`
StorageClass, then bootstraps Flux — including the four Secrets that cannot come from Flux,
because Flux needs them to resolve anything else. The full sequence is in
[Bootstrap and reconciliation](../gitops/flux.md#bootstrap-sequence).

The kubeconfig lands at `ansible/.generated/kubeconfig`, mode 0600, gitignored. Every `k0s:*`
and `fx:*` task points at it automatically.

```bash
task k0s:status
task fx:failing
```

Expect several minutes. Certificate issuance in particular waits on DNS-01 propagation. Anything
still failing after that, start at [Troubleshooting](troubleshooting.md).

## 10. The cloud plane

Pocket ID is running now, so create its admin API key at Settings → Admin → API Keys on
`auth.$DOMAIN`, and replace the `POCKETID_API_TOKEN` placeholder from step 1.

`tofu/oidc` writes into Infisical at the path the cluster is already watching, which is why it
goes last.

```bash
task tf:plan -- bunny && task tf:apply -- bunny
task tf:plan -- oidc  && task tf:apply -- oidc
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
