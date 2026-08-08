# Domains

One base domain, one file: `config/dns/dns.sops.yaml`, a SOPS-encrypted Secret with three keys.

| Key            | Is                                     | Example host                 |
| -------------- | -------------------------------------- | ---------------------------- |
| `DOMAIN`       | the base domain                        | `auth.$DOMAIN`               |
| `SUB_INTERNAL` | label for mesh-only services           | `dash.$SUB_INTERNAL.$DOMAIN` |
| `SUB_NODES`    | label NetBird answers peer names under | `kenaz.$SUB_NODES.$DOMAIN`   |

The labels are bare (`in`, `n`), not domains: a consumer always composes
`$SUB_INTERNAL.$DOMAIN`. Nothing else in the repo spells a domain out. Never hardcode one in an
app.

## Reading it

**Flux** — `infra/substitutions` publishes the Secret as `dns`. A consumer declares the
dependency and the source in its `ks.yaml`, then uses `${DOMAIN}` and `${SUB_INTERNAL}`
directly in its manifests:

```yaml
spec:
  dependsOn:
    - name: substitutions
  postBuild:
    substituteFrom:
      - kind: Secret
        name: dns
```

`infra/monitoring/ks.yaml` is the reference implementation. `dependsOn` names the Kustomization
that publishes the values; `substituteFrom` names the object this manifest reads.

`replacements` is not used for domains. It rewrites one delimiter-separated segment of a field,
which cannot reach a domain sitting mid-string — an OIDC discovery URL has a path after the
host — and mixing both mechanisms meant two ways to spell one value.

**Tofu** — `bunny`, `oidc` and `netbird` each declare the keys they need in their `refs.env`
and `sops --extract` them at plan time. No module keeps a copy. See
[Values another plane owns](../tofu/index.md#values-another-plane-owns).

**Ansible** — `just ans render-secrets` decrypts the same file into
`ansible/.generated/dns.yml`, and `inventory/group_vars/all/dns.yml` gives it a nested shape.
Use `{{ dns.domain }}`, `{{ dns.sub.nodes }}`, `{{ dns.sub.internal }}`; the flat capitals exist
only because a Kubernetes Secret cannot nest.

## Changing the domain

Edit the one file, then re-apply everything that resolved it:

```bash
just ops sops config/dns/dns.sops.yaml
just tf apply bunny
just tf apply netbird
just tf apply oidc
just ans setup
```

`netbird` moves the peer domain, so every node's `ansible_host` changes with it — Ansible
reaches the nodes by mesh name.

## Internal ingresses are unauthenticated

An `internal`-class `Ingress` is reachable by anything on the mesh, with no login in front of
it. `infra/auth` (Pocket ID) is a plain OIDC provider: it has no forwardAuth/verify endpoint of
the kind Authelia exposes, so Traefik has nothing to delegate a request to. Putting SSO in front
of an internal app needs an oauth2-proxy (or equivalent) bridge wired to Pocket ID first; until
that lands, mesh membership is the only access control these hosts have.

An app that speaks OIDC itself needs no bridge — it registers a client in `tofu/oidc` and
authenticates against Pocket ID directly. Grafana is the near-term case: `auth.generic_oauth`
is the natural fit and is not configured yet. `vmsingle` has no such option and waits on the
bridge.

## One thing that will bite you

In a plain manifest reconciled by a Flux `Kustomization`, escape a literal `$` as `$$`, or
envsubst will eat it. Both files under `infra/storage/app/storageclass-*.yaml` do this for
rclone's own `${pvc.metadata.*}` template variables.
