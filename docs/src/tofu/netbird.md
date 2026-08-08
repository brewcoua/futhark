# netbird

Manages the mesh: the account's own settings, its groups, every access rule, the route that puts
the cluster's service CIDR on the mesh, and the DNS zone that resolves internal hostnames for
peers. NetBird Cloud holds the control plane.

| File          | Owns                                                                    |
| ------------- | ----------------------------------------------------------------------- |
| `settings.tf` | The account's peer DNS domain and network range                         |
| `groups.tf`   | `node`, `k0s`, `admin`                                                  |
| `policy.tf`   | Every accept rule, including the all-protocol one the pod overlay needs |
| `route.tf`    | The k0s service CIDR, advertised into the mesh by the nodes             |
| `dns.tf`      | The internal DNS zone and its wildcard record                           |

[Pod to mesh networking](../ansible/networking.md#the-all-protocol-policy-rule) documents why the
node-to-node rule has to pass every protocol rather than just TCP/UDP/ICMP.

## Groups

Two axes. `node` is every machine this repo provisions; `k0s` is the workflow it runs. Today
every node is both, but the policies target the workflow, so a future node running something
else joins `node` and reaches nothing extra. `admin` is the operator's own devices, enrolled
from the dashboard.

`ansible/roles/netbird` puts a peer in `node` (`mesh_node_group`) and its workflow group
(`node.workflow` in `ansible/nodes/<host>/host.yml`) at join, by matching group _names_. Rename
a group here and the same name must change there, or the next join lands the peer outside every
rule.

## Access model

NetBird denies anything no rule accepts. These three rules are the whole model:

| Rule           | Direction        | Protocol      | For                               |
| -------------- | ---------------- | ------------- | --------------------------------- |
| `k0s mesh`     | `k0s` ↔ `k0s`    | all           | Cross-node pod traffic (IP-in-IP) |
| `admin to k0s` | `admin` → `k0s`  | all           | Internal ingress, the k0s API     |
| `admin ssh`    | `admin` → `node` | `netbird-ssh` | Administering a machine           |

Nothing else on the mesh reaches anything. A fresh account ships an enabled `Default` policy
(All → All) that silently overrides all of it — deleting it is step 3 of the bootstrap below.

`prevent_destroy` is set on the two rules carrying the operator's own access. Keep an SSH path
to the nodes open the first time you touch either.

## Bootstrap

Once per account, before the first `just ans setup`.

1. Create the NetBird Cloud account at <https://app.netbird.io>.
2. **Team → Users → Add service user**, then **Access Tokens** on that user, twice:
   - `netbird-policy` — used by this module, referenced from `secrets.sops.env`.
   - `netbird-enrollment` — used by `ansible/roles/netbird` to mint node setup keys, referenced
     from `config/secrets.sops.yaml`.

   Store both in Proton Pass under `futharkd/`. NetBird PATs cannot be scoped, so both carry
   full authority on the account; the split limits what a rotation disturbs, not what a leaked
   token can do. Issue them to a service user, not to your own account — a PAT tied to a person
   dies with that person's membership and takes both planes with it. They expire, 365 days at
   most: see [Checks](../operations/checks.md#netbird-token-expiry).

3. **Access Control → Policies**, delete the shipped `Default` policy.
4. Write this module's `secrets.sops.env` from its `.example`, then:

   ```bash
   just tf apply netbird
   ```

   This sets the peer DNS domain and the network range on the account, and creates the groups,
   policies, route and zone. Do it before any node joins: a peer that registered under the old
   domain or the old range has to re-register.

5. Install the client on your own devices, `netbird up`, then add each to the `admin` group from
   the dashboard. The operator machine's client comes with `just ops deps`; `just ops mesh`
   reports whether that machine is on the mesh yet.

Everything above except the account, the tokens and the `Default` deletion is declarative — the
dashboard is for enrolling peers, not for configuration. `settings.tf` writes the whole settings
object, so a knob changed in the dashboard is reverted on the next apply.

IPv6 overlay addressing (NetBird v0.71+) is not exposed by provider 0.0.9. Enable it from
**Settings → Network** if wanted; nothing here needs it.

## Applying

```bash
just tf plan netbird
just tf apply netbird
```

Nothing is import-first: each resource is created and owned individually. What this module
cannot do is check itself — NetBird has no server-side policy tests, so a wrong rule applies
cleanly and fails later, in traffic. The
[isolating test](../ansible/networking.md#the-isolating-test) is the substitute.

## Why the policy is safe to commit

It is keyed on group names and CIDRs, not on people or addresses: architecture, which this repo
already publishes in far more detail. Keep it that way — no user emails, no local usernames, no
peer addresses. The domain is identifying and is read at plan time from `config/dns/dns.sops.yaml`
via `refs.env`, never inlined. If a rule ever needs a literal user, pass it as a `TF_VAR` the
same way.

## The route and the DNS record

Internal hostnames resolve to one address: the `traefik-internal` Service's ClusterIP, pinned in
`infra/traefik-internal/app/helmrelease.yaml` and read straight out of that file by
`variables.tf`. `netbird_route.k0s_services` makes that address reachable — the nodes advertise
the whole service CIDR, NetBird fails the route over between them, and kube-proxy takes it from
there.

Two couplings no single file can enforce:

- The pinned ClusterIP has to stay inside `k0s_service_cidr`
  (`ansible/inventory/group_vars/all/network.yml`), the range the route advertises.
- `masquerade` on the route is load-bearing. Without it the reply is addressed to the client's
  mesh address, which the answering pod has no route back to.

The internal zone sits under a different label of the same domain as the peer domain — NetBird
refuses a custom zone that conflicts with it. Off-mesh, an internal hostname does not resolve at
all, which is the point.
