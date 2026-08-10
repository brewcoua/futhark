# Secrets

Which store a value belongs in, how each plane reads it, and why the cluster cannot reach the keys
that rebuild it. Read this before adding any secret, and [Adding a new secret](#adding-a-new-secret)
is the checklist at the end.

This repository is public. Nothing in it is a credential in the clear, and nothing in it is an
identifying value in the clear either: no real addresses, endpoints, account or key identifiers.

Three stores, chosen by what a value can _do_ rather than by who consumes it. Only two of them
hold credentials. SOPS is a file format rather than a service.

| Store                      | Holds                                                                             | Read by                                  |
| -------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------- |
| **SOPS**, encrypted in git | Identifying but non-granting: node addresses, the domain, account and project IDs | Ansible, OpenTofu, Flux                  |
| **Proton Pass**, one vault | Anything that can bootstrap or re-key the system                                  | `pass-cli`, on operator machines only    |
| **Infisical Cloud** (EU)   | Per-app runtime secrets                                                           | the Infisical operator, OpenTofu (write) |

The dividing line: publishing a node's IP would tie this repository to a machine, but the IP
grants nothing on its own, so that is SOPS. The Flux deploy key or the cluster age key grants
everything, so that is Proton Pass. A Grafana admin password is neither. It is one app's
operational secret, rotatable without touching anything else, so that is Infisical.

**The cluster holds no Proton Pass credential at all.** That is the whole tier boundary, and it
rests on absence rather than on a console-side path grant that could be misconfigured or drift. A
compromise of the cluster cannot reach the keys that rebuild it, because there is nothing in the
cluster to reach them with.

Drawn out, with the reads the table above already covers left off, so that the one edge that
matters is the only one competing for attention. The boundary is the arrow that is not there:
the red one, barred rather than pointed. Green is Proton Pass, the tier everything else is
rebuilt from. Amber is a third party this repository can write to but does not own. What the
cluster gets, it gets seeded once by Ansible, never by holding a credential of its own.

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
  external: {
    style: {
      stroke: goldenrod
      fill: cornsilk
    }
  }
  denied: {
    style: {
      stroke: firebrick
      stroke-dash: 4
    }
  }
}

operator: operator machine {
  gpg: GPG smartcard
  ansible: Ansible
  pat: Proton Pass token
}

pass: "Proton Pass\ndeploy key, age key, API tokens, API keys" {
  class: boundary
}
sops: SOPS in git\nnode addresses, domain, account IDs
infisical: "Infisical Cloud (EU)\nper-app runtime secrets" { class: external }

cluster: k0s cluster {
  flux: Flux
  infop: Infisical operator
  pods: pods
  infop -> pods: Secret
}

operator.gpg -> sops: decrypts
operator.pat -> pass: pass-cli, operator machines only
operator.ansible -> cluster: seeds age key,\ndeploy key, universal-auth

cluster.flux -> sops: decrypts, with the age key only
cluster.infop -> infisical: reads

pass -> cluster: "no credential, no path" {
  class: denied
  target-arrowhead.shape: cf-many
}
```

## SOPS

Everything encrypted lives in `config/sops/`, in two files. The split is the tier boundary and nothing
else: what the cluster may read, and what it may not.

| File                            | Sealed to               | Holds                                                                                                        | Read by                 |
| ------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------- |
| `config/sops/ops.sops.yaml`     | operator GPG key        | `ansible` (admin user, crown-jewel references), `nodes` (addresses), `tofu` (per-module variables)           | Ansible, OpenTofu       |
| `config/sops/cluster.sops.yaml` | operator GPG + age keys | one `flux-system` Secret, `cluster-values`: the domain and its labels, the edge addresses, the backup bucket | Flux, OpenTofu, Ansible |

`.sops.yaml` at the repository root names both paths exactly. A `*.sops.*` file anywhere else
matches no rule and fails to encrypt, which is the intended answer: adding a third file is a
decision, not an accident.

The cluster key opens `cluster.sops.yaml` alone. A compromise of `flux-system` yields the values
Flux already substitutes into running manifests and nothing more. See
[Why the operator store is separate](#why-the-operator-store-is-separate).

The operator recipient is the GPG **primary** key's full fingerprint. Primary, so rotating or
renewing the encryption subkey never edits `.sops.yaml`, because gpg picks the current
encryption-capable subkey itself. Full fingerprint rather than the 16-hex long ID, because 64-bit
key IDs are collision-generatable and this file decides who can read every secret here. The
encryption subkey lives on a smartcard, so every `sops -d` needs the token and its PIN.

The cluster recipient is a separate age keypair, generated by `just ops age-key`. It has to be
separate: a card-resident private key cannot be exported, and Flux needs one mounted in-cluster.
It is never a personal identity.

Each file is committed alongside a `.example` template showing its shape. The real file is created
once, at bootstrap, and encrypted before it is committed. Neither carries comments: SOPS encrypts
comments along with values, so anything written there is invisible until decrypted and rewrites the
whole ciphertext on every edit. Explanation belongs in the template or on this page. SOPS encrypts
values and leaves keys alone, so `kustomize build` still parses an encrypted manifest. Only Flux
needs the key.

Three resolvers, one per plane:

- **Ansible** reads decrypted output rather than the encrypted file. `just ans render-secrets`
  writes `ansible/.generated/{secrets,nodes,cluster}.yml`, and the playbooks and
  `inventory/group_vars/all/` load those. No lookup against SOPS appears in any task.
- **OpenTofu** extracts its module's section into the environment. See
  [Rules for every module](../tofu/index.md).
- **Flux** uses `spec.decryption` on every Kustomization, patched in once via
  `infra/kustomization.yaml` and `nodes/kustomization.yaml`. `flux/infra/ks.yaml` and
  `flux/nodes/ks.yaml` state it in full, since `flux/` has no kustomization of its own.

Rotating either recipient re-encrypts files rather than values. Both procedures are in
[Credential rotation](../operations/rotation.md#operator-identity).

## Proton Pass

The crown-jewel tier, in one vault. Its name is yours to choose and is written down nowhere in
this repository: every committed reference spells it `<vault>`, and `pass-cli` resolves against
whichever vault your session holds. Naming it after the Infisical project keeps the two remote
stores alike. It holds the Flux git deploy key, the cluster age private
key, all three Infisical machine identities, the two NetBird PATs, the Bunny API key and the
Pocket ID admin token.

It also holds the two keys that encrypt the backups, the Kopia repository password and the SSE-C
key. Those are the one deliberate duplication in this scheme. They are runtime secrets, so Velero
reads them from Infisical like everything else, but a copy lives here because losing access to
Infisical must not also mean losing the ability to decrypt B2. There is no recovery path if both
go, by construction. See [Backup and recovery](../operations/recovery.md#encryption).

**The admin SSH private key is not in it, and never will be.** It is the operator's own identity,
it already lives in `~/.ssh` on the machine doing the connecting, and Ansible never reads it. It
_authenticates with_ it, which SSH does on its own. Its public half stays in
`config/sops/ops.sops.yaml` as `ansible.admin.ssh_pubkey`: identifying, granting nothing.

Nothing in the repository holds a Proton Pass credential either. What a new operator machine needs
out of band is exactly two things, the GPG smartcard that opens SOPS and a Proton Pass personal
access token:

```bash
pass-cli info || PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_… pass-cli login
```

Replace `pst_…` with the token from the Proton Pass web app. `pass-cli` persists a session after
that, so it is a once-per-machine step and not a per-command prompt. `just ops pass-session`
checks it and prints this if it is missing.

### Two commands, and the brace rule that separates them

Both planes compose SOPS with Proton Pass, and both resolve **SOPS first, pass-cli second**. The
committed file holds references, and only the second step turns them into values. They use
different pass-cli subcommands, which take opposite syntax:

|                   | resolves                                   | ignores     | used by  |
| ----------------- | ------------------------------------------ | ----------- | -------- |
| `pass-cli inject` | `{{ pass://… }}` in a document             | bare URIs   | Ansible  |
| `pass-cli run`    | bare `pass://…` in an environment variable | braced URIs | OpenTofu |

**Ansible** reads the `ansible` subtree of `config/sops/ops.sops.yaml`, which maps the crown jewels
_this plane_ needs to `pass://<vault>/<item>/<field>` references under a nested `secrets:` key.
The `tofu` subtree is deliberately not read here: resolving it would write secrets to disk that
Ansible never uses. `just ans render-secrets` does the work, and `ans setup` and `ans k0s` depend
on it:

```bash
sops -d --extract '["ansible"]' config/sops/ops.sops.yaml | pass-cli inject -f -o ansible/.generated/secrets.yml
```

`--extract` yields that subtree's own keys at the top level, so the result is `admin:` and
`secrets:`. `--out-file` rather than a shell redirect, because it applies pass-cli's default `0600`
where `>` would use the umask. `ansible/.generated/` is gitignored. The playbooks load the result
with an explicit `vars_files`, and the roles then reference plain variables such as
`secrets.flux.deploy_key`. Keep `no_log: true` on those tasks.

Rendering first is not optional. `{{ }}` is Jinja syntax as well as pass-cli's, so Ansible loading
the decrypted-but-uninjected document would try to evaluate `pass://<vault>/flux/deploy key` as an
expression. Nothing under `group_vars/` or `host_vars/` is encrypted, and no vars plugin decrypts
anything, precisely so no braces survive to be misread.

**OpenTofu** reads its own module's section of the same file. Each `tofu.<module>` map carries that
module's credentials as bare `pass://` URIs alongside its identifying values, so `--output-type
dotenv` flattens the map into the environment and `pass-cli run` rewrites the URI-valued variables
in place:

```bash
sops -d --output-type dotenv --extract '["tofu"]["bunny"]' config/sops/ops.sops.yaml
```

Getting the braces backwards fails quietly in both directions. An unresolved reference is passed
through as a literal string, which surfaces as a bad credential rather than as a template error.

Because the committed files hold references and not values, updating a Proton Pass item **in
place** rotates a credential with no commit at all. That is what makes most of
[Credential rotation](../operations/rotation.md) cheap.

### Why the operator store is separate

Vault, item and field names are identifying, and this repository commits nothing identifying in
the clear. More than that, `config/sops/ops.sops.yaml` is a map to the keys that rebuild the cluster,
so it is sealed to the **operator GPG key only**. Sealing it to the cluster age key as well would
hand `flux-system` a map to the Flux deploy key and to the age key that decrypts it. That is the
whole reason the two files exist rather than one.

The cost is one deliberate duplication. `PUBLIC_IP` and `MESH_IP` in `cluster.sops.yaml` are
kenaz's addresses, which `nodes.kenaz` in `ops.sops.yaml` also records. They cannot be shared:
Flux needs them and cannot read the operator store. `ansible/roles/netbird` writes the mesh address
back into `ops.sops.yaml` after every join, so treat that as the canonical one and keep
`cluster.sops.yaml` in step by hand. Nothing detects drift between them.

## Infisical, and how tier isolation is enforced

Apps read their secrets through the [Infisical
operator](https://github.com/Infisical/kubernetes-operator), with an `InfisicalConnection` and an
`InfisicalAuth` per tier and one `InfisicalStaticSecret` per app. The project is laid out as
`/infra/<component>` and `/nodes/<hostname>/<app>`.

An `InfisicalStaticSecret` names only its `secretPath`. The project and environment slugs are
global, so they come from the `config/infisical` Kustomize Component, referenced as
`components: [../../../config/infisical]` in the overlay, and the slugs are written once. Change
the project there and nowhere else.

### What only exists in the Infisical console

Three things the repository cannot express, in the order they bite:

1. **The identity's project membership.** An identity can exist org-wide, authenticate fine, and
   still be refused every read. That surfaces as `Unauthorized access: status 403` from the
   operator, and as `ProjectMembershipNotFound` from the API, a membership problem wearing a
   permissions error's clothes. Granting an org-level role does not fix it. The identity has to be
   assigned to the project.
2. **Its role and paths.** `cluster-reader` gets read on `/infra/*` and `/nodes/*` in the `prod`
   environment, **minus `/infra/velero`**. `backup-reader` gets `/infra/velero` and nothing else.
   Both halves matter: the admission policy below already lets any infra namespace name an
   `/infra/*` path, so if `cluster-reader` keeps `/infra/velero` the backup tier's separate
   identity buys nothing.
3. **`accessTokenTrustedIps`**, the third isolation layer below. Set on both identities, scoped to
   the cluster's egress address, so it fails whenever that changes: after a node rebuild, or when
   a pod is rescheduled onto a node whose address was never listed.

None of this is reconciled. Nothing drifts back. When secrets stop resolving and the manifests
look right, check these before reading any more YAML. Rotating an identity's client secret leaves
all three untouched; replacing the identity itself does not. See
[Credential rotation](../operations/rotation.md#the-infisical-machine-identities).

Infisical's free tier caps identities at five, humans included, so identities are rationed rather
than minted per tier. `cluster-reader` is shared by the infra tier and every node tier. Kubernetes
auth is not an option either: Infisical would have to reach the k0s API server for a `TokenReview`,
and that API server is mesh-only. So one credential can, by itself, read almost the entire
project, and the isolation OpenBao used to enforce server-side has to be rebuilt in the cluster.

Three layers do that, none of them relying on a controller's good behaviour:

1. **Kubernetes RBAC.** The operator is installed once per tier, each with `scopedRBAC: true` and
   its own `scopedNamespaces`. The chart then emits a `Role` and `RoleBinding` per scoped namespace
   and no cluster-wide secrets `ClusterRole` at all. The node tier's ServiceAccount therefore has
   zero permissions in `infisical-infra` or any infra namespace. It cannot read the infra tier's
   `InfisicalAuth`, let alone write a Secret next to it. Each tier keeps its own copy of the
   credential in its own namespace for the same reason.
2. **A `ValidatingAdmissionPolicy`.** RBAC governs where a Secret may land, not which path may be
   read, so `infra/infisical-operator/config/validatingadmissionpolicy.yaml` pins
   `spec.sources[].secretPath` to the namespace's own tier, using the `futk.eu/tier` and
   `futk.eu/node` labels from [Namespaces](namespaces.md), and pins every target to the object's
   own namespace. It is evaluated by the API server, so a violating object is never persisted. No
   extra controller, no Kyverno.
3. **Trusted IPs.** Both identities have `accessTokenTrustedIps` set to the cluster's egress
   address in Infisical itself.

Both layers are testable, and [Checks and CI](../operations/checks.md#infisical-tier-isolation)
has the probes.

### The one path that gets its own identity

`/infra/velero` holds the Backblaze application key, the Kopia repository password and the SSE-C
key. Between them, that is everything needed to read every backup this cluster has ever taken.
Layer 2 is not enough for it: the admission policy pins an `InfisicalStaticSecret` to its
namespace's _tier_, so any infra namespace may legitimately name any `/infra/*` path,
`/infra/velero` included.

So the backup tier spends one of the five identities. `infisical-backup` is its own operator
install scoped to itself and `velero`, authenticating as `backup-reader`, which is granted
`/infra/velero` and nothing else, and `cluster-reader` is denied that path in return. The second
half is what makes it real, and it exists only in the Infisical console. Skip it and the tier is
decoration. `ansible/roles/flux_bootstrap` seeds this credential in its own task, separate from the
loop that seeds the shared one.

What still defeats it: a cluster-admin who can edit the policy or the HelmReleases. Flux reconciles
and prunes all three every 10 minutes, so drift reverts within one interval, but that is the honest
boundary. `sources[].tagSlugs` is a selection filter, not an authorization one. Do not treat it as
isolation.

## Naming

**Every secret name, in every store, is `SCREAMING_SNAKE_CASE`.** `BUNNY_API_KEY`,
`ADMIN_PASSWORD`, `NB_PAT`. No hyphens, no camelCase, no lowercase.

One rule, for three reasons. It is the intersection of what every store accepts, since Infisical's
key charset is narrower than Kubernetes' and a hyphen that works in one may not in the other. Most
of these values end up as environment variables anyway, where the shape is not a choice. And a
single rule means you never have to remember which store spells a thing which way.

The exception is Proton Pass, whose items and fields are lowercase-with-spaces, as in
`pass://<vault>/netbird-policy/token`. Nothing there is matched by name or becomes an environment
variable under that name. Every reference is a path, and the environment variable it lands in is
named by the consumer, not by the store. `NB_PAT` under `tofu.netbird` and
`ansible.secrets.netbird.api_token` are two different fields of two different items, and the names
say nothing about that. The paths do.

Kubernetes Secret **keys** are a separate question, because the consumer often dictates them and
upstream charts do not follow this convention. Where the consumer is configurable, point it at the
conforming name: `infra/monitoring/app/grafana/helmrelease.yaml` sets `userKey: ADMIN_USER` rather
than the chart's default. Where it is not, remap with a `template` block on the
`InfisicalStaticSecret` target:

```yaml
targets:
  - kind: Secret
    name: bunny-api
    namespace: cert-manager
    creationPolicy: Owner
    template:
      engineVersion: v1
      data:
        api-key: "{{ .BUNNY_API_KEY }}"
```

Two manifests need this today: `cert-manager` (`api-key`) and `storage` (`configData`). Remap in
the manifest rather than bending the name in Infisical. The constraint belongs to the chart, so it
should be visible next to the chart, not encoded as a mystery in a remote UI.

The same block also handles a consumer that wants a **file** rather than a value. `backup`
(`cloud`) and `storage` (`configData`) build an INI in the template and interpolate one Infisical
secret per credential. Store the credentials, not the file: a config blob in Infisical hides its
own structure from review, cannot be rotated a field at a time, and grants everything it contains
at once.

## The secrets outside GitOps

These exist to seed what Flux resolves for itself, so neither can come from Flux.
`ansible/roles/flux_bootstrap` creates both:

- `flux-system/sops-age`. Without it Flux cannot decrypt anything.
- `infisical-universal-auth`, one copy per tier namespace.

Plus `flux-system/git-deploy-key`, which is how Flux reaches the repository at all.

Being outside GitOps cuts both ways. Delete one of these namespaces and its seed Secret goes with
it, with nothing in the Flux tree to put it back. Every `InfisicalStaticSecret` in the cluster then
fails with `InfisicalAuth is not ready`, which reads like an operator problem and is not one.
Re-run the role:

```bash
just ans k0s
```

Verify: `just fx failing` is empty, and
`kubectl get infisicalstaticsecrets -A` shows every object ready.

## Adding a new secret

1. Decide the tier. Identifying but harmless goes in `config/sops/`: `cluster.sops.yaml` if Flux
   substitutes it, `ops.sops.yaml` otherwise. Anything that bootstraps or re-keys the system goes
   in Proton Pass, referenced from `ansible.secrets` for Ansible or from `tofu.<module>` for
   OpenTofu. One app's operational secret goes in Infisical. Name it `SCREAMING_SNAKE_CASE`, per
   [Naming](#naming).
2. For Infisical, put it under `/infra/<component>` or `/nodes/<hostname>/<app>` and add an
   `InfisicalStaticSecret` in the app's namespace, with `secretPath` only. Add
   `components: [<relative>/config/infisical]` to the overlay for the project and environment. If
   that namespace is new, declare it in `infra/namespaces/app/namespaces.yaml` and add it to the
   right tier's `scopedNamespaces` in `infra/infisical-operator/app/`. The operator cannot write
   there otherwise, and the chart's install fails outright if a scoped namespace does not exist.
3. For SOPS, add the key with `just ops sops config/sops/ops.sops.yaml` or
   `just ops sops config/sops/cluster.sops.yaml`, which decrypts, opens `$EDITOR` and re-encrypts in
   place. Add no comment: the file is ciphertext, and the explanation belongs in the matching
   `.example` template. A new key in `cluster.sops.yaml` also needs the consumer's
   `postBuild.substituteFrom` to name the `cluster-values` Secret.
4. Confirm both checks pass:

   ```bash
   pre-commit run sops-encrypted --all-files
   pre-commit run gitleaks --all-files
   ```

5. If the new value can ever need replacing, add it to
   [Credential rotation](../operations/rotation.md), including the case where it cannot be
   rotated at all.
