# Cold bootstrap

Building the whole thing from nothing, in order. Every step is re-runnable; none of them are
one-shot except the OpenBao init in step 5, which stops the play on purpose.

## 0. The operator machine

```bash
task ops:setup
```

That installs everything the rest of this page assumes — `ansible-core`, `ansible-lint`,
`yamllint`, `kubectl`, `helm`, `kustomize`, `k0sctl`, `flux`, `tofu`, `pre-commit`, Proton's
`pass-cli`, and `mdbook` — installs the repo's pre-commit hooks, and runs `tofu init` in every
module. It needs `dnf` and `uv` already present.

You must be logged into `pass-cli` and on the tailnet yourself: `k0s_cluster` resolves each
node's mesh address through MagicDNS from this machine.

## 1. Proton Pass items

Nothing below works until the vault holds the values the repo's `pass://` pointers name. Find
them by grepping for the pointers rather than working from a list here — a list would go
stale:

```bash
grep -rho 'pass://[^"'"'"']*' --include='*.yml' --include='*.yaml' --include='*.env' . | sort -u
```

They fall into four groups: the admin SSH identity, the Tailscale credentials and MagicDNS
suffix, each node's IP address, and the OVH KMS material for OpenBao's seal. The Flux git
deploy key and the per-module tofu credentials come later, at steps 4 and 7.

Getting the KMIP seal key right is the one genuinely fiddly part — see
[The OpenBao seal](#the-openbao-seal) below.

## 2. Node definitions

One `ansible/nodes/<hostname>/host.yml` per machine, symlinked into
`ansible/inventory/host_vars/` and listed in `ansible/inventory/hosts.yml`. The schema and the
exact commands are in [Nodes](../ansible/nodes.md#adding-a-node).

## 3. Host provisioning

```bash
task ans:setup
```

Update, admin user, SSH hardening, mesh join, firewall. Add `-- <host>` to limit it to one
machine. Safe to re-run; `ssh_identity` picks whichever login currently answers.

After the first run each host answers only as the admin user on the hardened port. If you are
provisioning several nodes one at a time, the mesh-peer resolution in `roles/tailscale`
retries while MagicDNS catches up, so ordering between them does not matter.

## 4. Tailnet policy

Do this **before** the cluster comes up, not after. Cross-node pod networking needs the
`ip-in-ip` rule, and without it the cluster fails in a way that looks like an OpenBao seal
fault rather than a network one.

```bash
task tf:plan -- tailscale
```

The first apply needs an import first — read [tailscale](../tofu/tailscale.md#first-apply) in
full before running it, because the resource owns the entire policy document.

Also required at this step: the Flux git deploy key. Generate an SSH keypair, add the public
half as a deploy key on the repository, and store the private half in the Proton Pass item
`ansible/roles/flux_bootstrap` points at.

## 5. Cluster and Flux

```bash
task ans:k0s
```

This renders `k0sctl.yaml` from inventory, converges the cluster, installs the `local-path`
StorageClass, creates OpenBao's namespace and seal Secret, then bootstraps Flux. The full
sequence is in [Bootstrap and reconciliation](../gitops/flux.md#bootstrap-sequence).

The kubeconfig lands at `ansible/.generated/kubeconfig`, mode 0600, gitignored. Every `k0s:*`
and `fx:*` task points at it automatically.

Then initialize OpenBao, once:

```bash
task bao:policy-sync
```

On a fresh OpenBao this runs `bao operator init`, prints the recovery keys and root token, and
**stops the play**. Those values are never written to disk. Copy the root token into the
Proton Pass item the role reads back — `futharkd/openbao/root token` — before doing anything
else. The recovery keys are only needed to mint a new root token later; the KMIP seal handles
day-to-day unsealing, so there is no Shamir key to manage.

Then run it again:

```bash
task bao:policy-sync
```

The second run does the actual work: it creates the `infra` namespace plus one
`node-<hostname>` namespace per `nodes/*.k0s/` directory, each with its own `secret/` kv-v2
mount, `kubernetes` auth mount, and `reader`/`oidc-writer` policies. It is idempotent — run it
again any time you add a node.

## 6. Watch it converge

```bash
task k0s:status
task fx:failing
```

Flux reconciles `openbao` first and everything else behind it. Expect several minutes; the
certificate issuance in particular waits on DNS-01 propagation. Anything still failing after
that, start at [Troubleshooting](troubleshooting.md).

## 7. The cloud plane

```bash
task tf:plan -- bunny && task tf:apply -- bunny
task tf:plan -- oidc  && task tf:apply -- oidc
```

Each has its own prerequisites — see [bunny](../tofu/bunny.md) and [oidc](../tofu/oidc.md).
`oidc` in particular needs an OpenBao token minted from step 5's root token, which is why it
comes last.

## The OpenBao seal

OpenBao auto-unseals against an OVH KMS KMIP endpoint. Two things about the setup are easy to
get wrong, and both fail at startup in misleading ways.

**The key id must be the KMIP object UID**, not the OVH service key id and not its URN. `okms
keys` and `okms kmip` are separate namespaces, and OpenBao never creates key material itself.
Create and activate the object explicitly — OpenBao rejects a key that is not active:

```bash
okms kmip create symmetric --alg AES --size 256 --usage encrypt,decrypt
okms kmip activate <id>
```

Feeding it a service key id instead fails with a KMIP `ItemNotFound` on `GetAttributes`, which
reads as "the key was deleted" and is not that.

**The credential needs exactly three IAM actions.** The seal wrapper only ever issues three
KMIP operations — `GetAttributes` at startup to verify the object, then `Encrypt` and
`Decrypt` to wrap the root key:

```text
okms:kmip:getAttributes   (READ)
okms:kmip:encrypt         (OPERATE)
okms:kmip:decrypt         (OPERATE)
```

Deliberately not granted: `okms:kmip:get` returns the raw key material, which defeats the
point of a seal whose wrapping key never leaves the HSM. `okms:kmip:destroy` and
`okms:kmip:rekey` can render every existing ciphertext — the whole OpenBao store —
permanently unreadable, and the recovery keys do not help, since they only mint a new root
token. `activate` is only needed when creating the key, so use an admin credential for that
step, not this one.

A missing action surfaces as `Operation is not authorized` on `GetAttributes`. That one is not
about the key id at all; fix the policy, not the key.

`okms kmip locate` is not a valid way to check any of this: OVH exposes no IAM action for
Locate, so it returns "not authorized" even for a correctly permissioned credential.
