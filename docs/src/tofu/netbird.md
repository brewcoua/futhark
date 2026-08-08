# netbird

Manages the mesh's access control, the route that puts the cluster's service CIDR on the mesh,
and the DNS zone that resolves internal hostnames for peers. NetBird Cloud holds the control
plane; everything this repo can state about the account is stated here.

Four files, one concern each:

| File        | Owns                                                                                       |
| ----------- | ------------------------------------------------------------------------------------------ |
| `groups.tf` | `futhark-nodes` (the k0s nodes) and `futhark-admins` (the operator's own devices)          |
| `policy.tf` | Every accept rule, including the all-protocol node-to-node rule the pod overlay depends on |
| `route.tf`  | The k0s service CIDR, advertised into the mesh by the nodes                                |
| `dns.tf`    | The NetBird DNS zone for `INT_DOMAIN` and its wildcard record                              |

[Pod to mesh networking](../ansible/networking.md#the-all-protocol-policy-rule) documents why
the node-to-node rule has to pass every protocol rather than just TCP/UDP/ICMP.

## Why the policy is safe to commit

It is keyed on group names and CIDRs, not on people or addresses: architecture, which this repo
already publishes in far more detail, rather than values. Keep it that way — no user emails, no
local usernames, no `100.x` peer addresses. The internal domain is identifying and is read at
plan time from the file Flux already owns (`refs.env`), never inlined. If a rule ever genuinely
needs a literal user, pass it as a `TF_VAR` from `refs.env` or `secrets.sops.env`, the same
pattern as [`bunny`](bunny.md).

## Deny-by-default, and the policy that isn't

NetBird denies anything no rule accepts. A fresh account ships with a `Default` policy that
accepts everything between everything, and this module does not manage it — delete it once,
from the dashboard, or the rules here describe an access model that is not the one being
enforced.

`policy.baseline` is deliberately just as open. Narrowing it is a change to make on purpose;
until then the two narrower policies document intent rather than enforce it.

## Before the first apply

Create the account, then a **service user**, then two Personal Access Tokens on that user, and
store both in Proton Pass:

- `netbird-policy` — used by this module, referenced from `secrets.sops.env`.
- `netbird-enrollment` — used by `ansible/roles/netbird` to mint node setup keys, referenced
  from `config/secrets.sops.yaml`.

NetBird PATs cannot be scoped, so both carry full authority on the account; the split limits
what a rotation disturbs, not what a leaked token can do. They also expire — 365 days at most —
so rotation is a standing item in
[Checks](../operations/checks.md#netbird-token-expiry).

Issue them to a service user, not to your own account: a PAT tied to a person dies with that
person's membership, and takes both planes with it.

## Applying

```bash
just tf plan netbird
just tf apply netbird
```

Nothing here is import-first: each resource is created and owned individually, so a first apply
adds rather than replaces. What it cannot do is check itself — NetBird has no server-side policy
tests, so a rule that is wrong applies cleanly and fails later, in traffic. The
[isolating test](../ansible/networking.md#the-isolating-test) is the substitute.

`prevent_destroy` is set on `policy.baseline` and `policy.ssh`, the two that carry the
operator's own access. Keep an SSH path to the nodes open the first time you touch either.

## The route and the DNS record

Internal hostnames resolve to one address: the `traefik-internal` Service's ClusterIP, pinned
in `infra/traefik-internal/app/helmrelease.yaml` and read straight out of that file by
`variables.tf`. `netbird_route.k0s_services` is what makes that address reachable — the nodes
advertise the whole service CIDR, NetBird fails the route over between them, and kube-proxy
takes it from there.

Two couplings that no single file can enforce:

- The pinned ClusterIP has to stay inside `k0s_service_cidr`
  (`ansible/inventory/group_vars/all/network.yml`), which is the range the route advertises.
- `masquerade` on the route is load-bearing. Without it the reply is addressed to the client's
  mesh address, which the answering pod has no route back to.

`INT_DOMAIN` still has a Bunny zone — [`bunny`](bunny.md) explains what is left in it — but no
record in it points into the mesh anymore. Off-mesh, an internal hostname does not resolve at
all, which is the point of the internal domain.
