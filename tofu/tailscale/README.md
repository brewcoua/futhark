# tailscale

Manages the tailnet policy file (`policy.hujson`) — the mesh's access control, including the
`ip-in-ip` rule the pod overlay depends on.

This is the one piece of the mesh that used to live nowhere but the Tailscale admin console, so
it could not be reproduced from this repo and drifted silently. `ansible/nodes/README.md`
("Tailnet ACL prerequisite") documents why the `ip-in-ip` rule exists.

## Why the policy is safe to commit

The policy is keyed on tags and autogroups, not on people or addresses — architecture, which
this repo already publishes in far more detail, rather than values. Keep it that way: no user
emails, no `100.x` node addresses, no tailnet name. The tailnet name and the OAuth credentials
are identifying, so they stay in `secrets.env` as `pass://` pointers. If a rule ever genuinely
needs a literal user, switch `acl.tf` to `templatefile()` and pass it as a `TF_VAR` pointer —
same pattern as `tofu/bunny`.

## First apply

`tailscale_acl` owns the **entire** policy document, and `policy.hujson` in git is a seed, not a
`policy.hujson` was seeded from the live policy as of the module's first commit, and matches it
structurally except for the added `tests` block. Confirm that is still true rather than assuming
it: anything the file omits is deleted from the tailnet on apply, including the rules granting
your own access. `overwrite_existing_content` is deliberately unset, so the provider refuses to
apply until the live policy has been imported:

```bash
cd tofu/tailscale
tofu init
pass-cli run --env-file secrets.env -- tofu import tailscale_acl.this acl
pass-cli run --env-file secrets.env -- tofu plan
```

Read the plan before applying. If the tailnet has been edited in the admin console since, the
diff shows it — reconcile into `policy.hujson` rather than letting the apply revert it:

```bash
pass-cli run --env-file secrets.env -- tofu apply
```

(`task tf:plan -- tailscale` / `task tf:apply -- tailscale` wrap this. `task tf:init` with
no module inits every module under `tofu/`.)

Keep an SSH path to the nodes open the first time. A policy that locks you out of the tailnet
also locks you out of fixing it.

## Tests

The `tests` block is evaluated server-side when the policy document is written, so a failing
test aborts `tofu apply` and the tailnet keeps its previous policy — the regression never lands.
It is **not** caught at plan time; plan does not submit the document, so a green plan says
nothing about the tests. Expect a failure to surface as `Error: Failed to update ACL —
test(s) failed (400)`.

That is the main reason this module exists: the missing `ip-in-ip` rule took the cluster down
and presented as an OpenBao seal fault three layers away. Add a test whenever a rule turns out
to be load-bearing.

Protocols that do not use ports are tested against port **0**, not `*` — the same rule the
Tailscale docs give for `icmp`. A test written `tag:futhark-node:*` is rejected with
`invalid port "*"`. To check a policy without writing it:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @policy.json \
  "https://api.tailscale.com/api/v2/tailnet/$TAILSCALE_TAILNET/acl/validate"
```

`{}` means valid; a failing test returns `{"message":"test(s) failed", ...}`. The endpoint takes
strict JSON, so strip the comments and trailing commas from `policy.hujson` first.

## Before the first apply

Populate the Proton Pass items `secrets.env` points at:

- `futharkd/tailscale/tailnet` — the tailnet name (e.g. the `*.ts.net` name or the org domain).
- `futharkd/tailscale/oauth client id` / `oauth client secret` — an OAuth client created in the
  admin console under Settings → OAuth clients, with **write** access to the policy file.

Then, in the admin console's policy file management page, set **External reference** to this
directory's URL and enable **Prevent edits in the admin console** — the former is only a link
for other admins, the latter is what actually stops console edits from drifting from git. API
writes (this module) keep working with the lock on.
