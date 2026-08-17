# netbird

Declares the mesh: the NetBird account's own settings, its groups, every access rule, and the DNS
zone that resolves internal hostnames for peers. NetBird Cloud holds the control plane. Applying
this module leaves an account whose access model matches this repository, with nothing configured
by hand except the account itself, the two service users and their tokens.

| File          | Owns                                                                    |
| ------------- | ----------------------------------------------------------------------- |
| `settings.tf` | The account's peer DNS domain and network range                         |
| `groups.tf`   | `node`, `k8s`, `admin`                                                  |
| `policy.tf`   | Every accept rule, including the all-protocol one the pod overlay needs |
| `dns.tf`      | The internal DNS zone and its wildcard record                           |

## Prerequisites

- A NetBird Cloud account, with the shipped `Default` policy deleted. [Bootstrap](#bootstrap)
  below creates both.
- Two service users and a Personal Access Token on each. Roles matter and are covered below.
- The `tofu.netbird` section of `config/sops/ops.sops.yaml`, written from its `.example`, holding
  `NB_PAT` as a `pass://` reference.
- The common module rules in [Rules for every module](index.md), including how `refs.env` and a
  module's own section are composed at plan time.
- Provider `netbirdio/netbird` pinned to exactly `0.0.9`, and OpenTofu `>= 1.7.0`. The pin is
  exact because a `0.0.x` provider promises nothing between patch releases.

## Applying

```bash
just tf plan netbird
just tf apply netbird
```

Nothing is import-first. Each resource is created and owned individually.

The first apply, and any later change to `settings.tf`, needs an elevated role. See
[Applying account settings](#applying-account-settings).

## Bootstrap

Once per account, before the first `just ans setup`.

### 1. Create the account

Sign up at <https://app.netbird.io>.

### 2. Create the two service users and their tokens

**Team → Users → Add service user**, twice. The role is a mandatory field and is the only scoping
a NetBird token has: a PAT inherits the role of the user it belongs to, and carries neither more
nor less.

| Service user | Role              | Token                | Used by                                                    |
| ------------ | ----------------- | -------------------- | ---------------------------------------------------------- |
| enrollment   | **Admin**         | `netbird-enrollment` | `ansible/roles/netbird`, referenced from `ansible.secrets` |
| policy       | **Network Admin** | `netbird-policy`     | this module, referenced from `tofu.netbird`                |

Then **Access Tokens** on each user, one token each, named for the token column. Expiry is
mandatory and capped at 365 days. The plaintext is shown once and stored hashed, so file it in
Proton Pass before closing the dialog.

Issue both to service users, never to your own account. A PAT tied to a person dies with that
person's membership and takes its plane with it. Two users rather than one because the roles
genuinely differ: a leaked `netbird-policy` cannot enrol a peer, and either token rotates without
disturbing the other plane.

What each role buys:

| Token                | Calls                                     | Needs                        |
| -------------------- | ----------------------------------------- | ---------------------------- |
| `netbird-enrollment` | `GET /api/groups`, `POST /api/setup-keys` | write on Setup Keys          |
| `netbird-policy`     | groups, policies and the DNS zone below   | write on Access Control, DNS |

Network Admin can read Setup Keys but cannot create one, so the enrollment user cannot drop to it.
Admin is the lowest role that mints a setup key.

The enrollment PAT is reached for only on a peer's first join. An already-connected peer skips the
lookup and the mint, and what it mints there never lands on the node. See
[why no credential lives on a node](../ansible/mesh-watchdog.md#stuck-and-why-no-credential-lives-on-a-node).

Account settings are the one thing `netbird-policy` cannot write, and
[Applying account settings](#applying-account-settings) is how that is handled.

### 3. Delete the shipped `Default` policy

**Access Control → Policies**, delete `Default`.

A fresh account ships this policy enabled, All to All, every protocol. It silently overrides the
whole access model below. Leave it and the rules this module applies describe an access model
nothing is enforcing.

Verify: the policy list is empty before the first apply.

### 4. Write the secrets file and apply

```bash
just ops sops config/sops/ops.sops.yaml
just tf init netbird
just tf plan netbird
just tf apply netbird
```

This first apply creates `netbird_account_settings`, so read
[Applying account settings](#applying-account-settings) before running it.

Do it before any node joins. A peer that registered under the old peer domain or the old network
range has to re-register.

Verify: **Settings → Network** shows the peer DNS domain and network range from
`config/sops/cluster.sops.yaml` and `ansible/inventory/group_vars/all/network.yml`, and
`just tf plan netbird` is a no-op.

### 5. Enrol your own devices

Install the client, run `netbird up`, then add each peer to the `admin` group from the dashboard.
The operator machine's client arrives with `just ops deps`.

Verify:

```bash
just ops mesh
```

It reports whether this machine is on the mesh.

## Applying account settings

`netbird_account_settings` writes `dns_domain` and `network_range`, which NetBird treats as
account Settings. **Network Admin can read those and not write them**, so the `netbird-policy`
service user cannot apply this resource at its normal role. That covers the first apply and every
later edit to `settings.tf`.

The fix is to raise the service user's role for the duration of the apply. A PAT inherits its
user's role, so nothing is reissued and `NB_PAT` does not change.

1. In the dashboard, **Team → Users**, open the **policy** service user and set its role to
   **Admin**.
2. Run the apply:

   ```bash
   just tf plan netbird
   just tf apply netbird
   ```

3. Verify the apply took: `just tf plan netbird` reports no changes, and **Settings → Network**
   shows the values from `settings.tf`.
4. Set the same user back to **Network Admin**. Do this immediately, in the same sitting.
5. Verify the demotion. `just tf plan netbird` must still report no changes, because a clean plan
   only reads. To confirm the write path is actually closed again, change `dns_domain` locally,
   run `just tf plan netbird`, and expect the apply to be refused with a 403 rather than to
   succeed. Discard the local change afterwards.

Why the demotion matters: this token is long-lived, lives in a vault, and is deliberately the
narrower of the two. Left at Admin it can also mint setup keys, which erases the split that is the
entire reason there are two service users.

If you minted a token ad hoc for a one-off apply rather than promoting the existing user, delete
it in the dashboard as soon as step 3 passes. Do not leave it to its 365 day expiry. Scheduled
rotation of the two standing tokens is
[Credential rotation](../operations/rotation.md#the-netbird-tokens).

## Failure modes

**`403` on `netbird_account_settings`.** The policy service user is at Network Admin. Follow
[Applying account settings](#applying-account-settings).

**`401` on any call.** The PAT has expired or been deleted. Both are capped at 365 days. See
[Checks and CI](../operations/checks.md#netbird-token-expiry) for what each token's expiry breaks, and
[Credential rotation](../operations/rotation.md#the-netbird-tokens) for the replacement procedure.

**A node joins and reaches nothing.** A group was renamed here but not in
`ansible/roles/netbird`, which matches by group name. See [Groups](#groups).

**Everything reaches everything.** The shipped `Default` policy is still enabled. Step 3.

**A rule applies cleanly and traffic still fails.** NetBird has no server-side policy tests, so a
wrong rule is accepted and only fails later, in traffic. The
[isolating test](../ansible/networking.md#the-isolating-test) is the substitute.

## Groups

Two axes. `node` is every machine this repository provisions. `k8s` and `podman` are the workflows
those machines run. The policies target the workflow rather than the fleet, which is what the second
axis buys: `brokkr` runs containers under Podman with no Kubernetes API, so it joins `node` and
`podman` and reaches nothing the `k8s` rules open. `admin` is the operator's own devices, enrolled
from the dashboard.

`ansible/roles/netbird` puts a peer in `node` (`mesh_node_group`) and in its workflow group
(`node.workflow` in `ansible/nodes/<host>/host.yml`) at join, matching group **names**. Rename a
group here and the same name must change there, or the next join lands the peer outside every
rule. The same coupling means **a new `workflow` value needs its group created here before that
node's first join**, or the setup key's `auto_groups` names a group that does not exist.

`podman` has no policy of its own, and needs none: `brokkr`'s inbound traffic is public and arrives
on 443 rather than over the mesh, and administering it is already covered by `admin ssh` below,
which targets `node`.

`peers` carries `ignore_changes` on all four groups. Ansible fills it, and without the lifecycle
block an apply would empty the group again.

## Access model

NetBird denies anything no rule accepts. These three rules are the whole model:

| Rule           | Direction         | Protocol      | For                                  |
| -------------- | ----------------- | ------------- | ------------------------------------ |
| `k8s mesh`     | `k8s` to `k8s`    | all           | Cross-node pod traffic (CNI overlay) |
| `admin to k8s` | `admin` to `k8s`  | all           | Internal ingress, the Kubernetes API |
| `admin ssh`    | `admin` to `node` | `netbird-ssh` | Administering a machine              |

Only the first is bidirectional. Nothing on the cluster needs to dial a laptop.

[Pod to mesh networking](../ansible/networking.md#the-all-protocol-policy-rule) documents why the
node-to-node rule has to pass every protocol rather than just TCP, UDP and ICMP.

`prevent_destroy` is set on the two rules carrying the operator's own access. Keep an SSH path to
the nodes open the first time you touch either.

The SSH rule matches `netbird up --allow-server-ssh` in `ansible/roles/netbird`. Without that flag
the rule matches and the peer still refuses the session. `authorized_groups` is deliberately
unset: setting it whitelists local usernames, which are identifying values this repository does
not commit. Unset, every local account is reachable, gated by that account's own
`authorized_keys` and by membership of `admin`.

## The DNS record

Internal hostnames resolve to one address: the mesh address of the node `traefik-internal` binds
443 on with `hostNetwork` (`infra/traefik-internal/app/helmrelease.yaml`). It comes from
`refs.env`, out of the `nodes` map in `config/sops/ops.sops.yaml` that `roles/netbird` writes after
each join, so no copy of it is maintained by hand.

This module advertises no route. A peer's own address is reachable from every peer the policies
allow, so nothing has to be routed for the record to work. Moving internal ingress to another node
means updating the `nodeSelector` in that HelmRelease and the hostname in `refs.env`, then
applying this module. Nothing detects disagreement between them, and the failure is a wildcard
pointing at a node that answers nothing on 443.

The predecessor was `netbird_route.k8s_services`, which advertised the whole cluster service CIDR
so peers could reach a pinned `ClusterIP`. It needed `masquerade` for the reply path, a `/32`
inside `k8s_service_cidr`, and both nodes as routing peers, and it broke in a way no control-plane
surface showed: the client reported the route `Selected` while no packet crossed. The peer-address
form has none of those parts.

The internal zone sits under a different label of the same domain as the peer domain, because
NetBird refuses a custom zone that conflicts with it. Off-mesh, an internal hostname does not
resolve at all, which is the point. One wildcard record covers every internal app, so adding one
needs no apply here.

## What is declarative and what is not

Everything except the account, the two service users, their tokens and the `Default` deletion. The
dashboard is for enrolling peers, not for configuration. `settings.tf` writes the whole settings
object, so a field left unset there is set from the resource's own defaults rather than from
whatever the dashboard currently holds, and a knob changed in the dashboard is reverted on the
next apply.

IPv6 overlay addressing (NetBird v0.71 and later) has no field in provider 0.0.9. Enable it from
**Settings → Network** if you want it. Nothing here needs it.

## Why the policy is safe to commit

It is keyed on group names and CIDRs, not on people or addresses. That is architecture, which this
repository already publishes in far more detail. Keep it that way: no user emails, no local
usernames, no peer addresses. The domain is identifying and is read at plan time from
`config/sops/cluster.sops.yaml` via `refs.env`, never inlined. If a rule ever needs a literal user, pass
it as a `TF_VAR` the same way.
