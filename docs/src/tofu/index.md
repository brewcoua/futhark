# Rules for every module

The rules every module under `tofu/` follows, their two deliberate exceptions, and how to run
one. Read this before writing or applying any module.

`tofu/` covers provider-API resources Flux and Kustomize cannot own, because they live outside the
cluster: a DNS record, a registrar account, a mesh policy.

It is not used for anything Flux can reconcile. Pocket ID itself is a Flux-managed workload under
`infra/auth/`, not a tofu resource. The [`oidc`](oidc.md) module only registers its OIDC clients,
an operation against Pocket ID's own API that no Kustomization can express.

## Rules

**Read-only against the secret stores.** Never let a module write to one. Anything a module
_mints_ becomes a `sensitive` output, filed by hand.

_Exception: [`oidc`](oidc.md)._ It mints OIDC client secrets in Pocket ID, and the whole point
of the module is removing that hand-paste step for this one round trip, so it writes those
secrets straight to Infisical. It authenticates as a machine identity scoped to write one folder,
`/nodes/<hostname>/<app>`, and is deliberately not the read-only identity the cluster uses. Every
other module stays read-only.

**Provider tokens are never committed, in any form.** A module's `secrets.sops.env` holds two
kinds of line, and neither is a value. Identifying values that grant nothing, such as a real
public IP or an account ID, appear as `TF_VAR_<name>=...`. Credentials appear as bare `pass://`
references that `pass-cli run` resolves after `sops exec-env` has loaded the file. No braces:
`run` resolves bare URIs and ignores braced ones, the inverse of `inject`. See
[Secrets](../conventions/secrets.md).

A genuinely non-identifying constant shared with other parts of the repository, such as the mesh
and service CIDRs or `traefik-internal`'s pinned ClusterIP, is read straight from its committed
source as a `local` rather than duplicated into `terraform.tfvars`. The domain is identifying, so
it comes through `refs.env` instead. See [Domains](../conventions/domains.md).

**State stays local and gitignored.** `tofu/**/.terraform/`, `tofu/**/*.tfstate*` and
`tofu/**/crash.log` are all excluded. A module's minted credentials can sit in state in plaintext
even when marked `sensitive`, which only suppresses console and plan output. Keep state on the
operator machine. `.terraform.lock.hcl` is the provider version lockfile and **is** committed.

_Exception: [`b2`](b2.md)._ Local state makes a module non-portable, and for that one module
non-portable means broken. `b2_bucket` can only be imported by bucket id, and B2 bucket names are
globally unique, so a second operator machine starting from empty state does not adopt the bucket.
It fails the apply with `duplicate_bucket_name`. Its state lives in a B2 bucket instead, written
under SSE-C with a key from Proton Pass, so the plaintext credential in it is ciphertext to
Backblaze. Every other module keeps its state local.

**Verify provider resource and attribute names** against current provider docs before the
first apply.

## Running a module

```bash
just tf init [<module>]   # provider download only, unless the module has a backend
just tf plan <module>
just tf apply <module>
```

`just tf init` with no module argument inits every module under `tofu/`, and runs as part of
`just ops setup`. `plan` and `apply` compose both stores, in this order:
`sops exec-env secrets.sops.env 'pass-cli run -- tofu <cmd>'`. That needs a Proton Pass session
(`pass-cli info`) and the GPG smartcard present. Neither ever writes a value to disk.

`init` composes them too, but only for a module that ships a `backend.tf`, because initialising a
remote backend means authenticating against it. `just tf init` with no argument therefore asks for
the card and a Pass session as soon as one such module exists. The other modules still init on
nothing but a network connection.

One module needs more than a credential to apply: `netbird` writes account settings its own token
cannot reach at its normal role. See
[Applying account settings](netbird.md#applying-account-settings).

### Values another plane owns

A module never keeps its own copy of a value that already lives somewhere else. It declares a
reference in `refs.env`, which `plan` and `apply` resolve before running:

```
# <variable>=<repo-relative .sops file>#<sops --extract expression>
TF_VAR_kenaz_public_ip=ansible/nodes/kenaz/host.sops.yml#["node_ip"]
TF_VAR_domain=config/dns/dns.sops.yaml#["stringData"]["DOMAIN"]
```

The expression goes to `sops --extract` verbatim, so one line shape reaches a node fact and a
Flux Secret alike. Who owns what:

| Value                               | Owner                                               | Why                                                                                                                                                      |
| ----------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| node addresses                      | `ansible/nodes/<node>/host.sops.yml`                | `roles/netbird` writes `node_mesh_ip` back into it after each mesh join, so it is recorded where it is discovered                                        |
| the domain and its subdomain labels | `config/dns/dns.sops.yaml`                          | Flux substitutes the same keys into manifests, and Ansible reads them too                                                                                |
| the backup bucket and its region    | `infra/substitutions/app/backup-location.sops.yaml` | Velero's `BackupStorageLocation` is a CR whose bucket is fixed when Flux renders it, so that file has to hold it. [`b2`](b2.md) provisions what it names |

A value that is neither identifying nor secret needs no reference at all: `tofu/netbird` reads
the mesh CIDR, the k0s service CIDR and `traefik-internal`'s pinned ClusterIP straight out of
the committed files that own them, as `local`s.

`refs.env` holds only references, so it is committed in the clear even though every file it
names is encrypted. All of them seal to the same operator key, so resolving one costs no extra
card touch. A module without the file is unaffected.

**A variable in both `refs.env` and `secrets.sops.env` is not a harmless duplicate.**
`sops exec-env` runs _after_ the refs are exported, so the encrypted copy wins and the ref is
silently dead. Keep each value in exactly one of the two.

`infra/substitutions/app/edge-ips.sops.yaml` is the reverse direction and keeps its own copy: Flux
decrypts it in-cluster, so it is sealed to the cluster age key as well, and `.sops.yaml`
deliberately keeps that key away from everything under `ansible/` and `tofu/`.

The pre-commit `tofu-validate` hook only runs `fmt` and `validate`, never `init`, because a hook
that touches `.terraform.lock.hcl` fails pre-commit's own "did this hook modify a file" check. Run
`just tf init` once locally before committing. CI runs init as its own step first. See
[Checks and CI](../operations/checks.md).

## Modules

| Module                  | Manages                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| [`bunny`](bunny.md)     | Public DNS records in the existing Bunny DNS zone                                        |
| [`oidc`](oidc.md)       | Pocket ID OIDC clients, writing the minted secret into Infisical                         |
| [`netbird`](netbird.md) | Mesh access policy, the route onto the cluster's service CIDR, and the internal DNS zone |
| [`b2`](b2.md)           | The Backblaze B2 bucket Velero backs up to, and the application key it uses              |

What each touches. Every arrow into a secret store is a read except the one marked in red, which
is the whole read-only rule and its single exception: `oidc` writes under a separate identity,
scoped to `/nodes/<host>/<app>`. Amber marks a third party this repository calls but does not
own, including the state bucket, which was created by hand.

```d2
direction: down

classes: {
  external: {
    style: {
      stroke: goldenrod
      fill: cornsilk
    }
  }
  danger: {
    style: {
      bold: true
      stroke: firebrick
    }
  }
}

pass: Proton Pass
sops: SOPS in git
infisical: Infisical { class: external }

modules: "tofu/" {
  bunny
  oidc
  netbird
  b2
}

pass -> modules: provider tokens\n(pass-cli run)
sops -> modules: identifying values\n(sops exec-env, refs.env)

modules.bunny -> bunny-api: DNS records
modules.netbird -> nb-api: policies, route, DNS zone
modules.oidc -> pocketid: OIDC clients
modules.b2 -> b2-api: bucket, Velero's key
modules.b2 -> b2-state: "its own state, SSE-C\n(the one remote backend)"

bunny-api: Bunny DNS API { class: external }
nb-api: NetBird API { class: external }
pocketid: "Pocket ID API\n(a Flux-managed workload)"
b2-api: Backblaze B2 API { class: external }
b2-state: "B2 state bucket\n(created by hand, unmanaged)" { class: external }

modules.oidc -> infisical: WRITES the minted secret { class: danger }
```
