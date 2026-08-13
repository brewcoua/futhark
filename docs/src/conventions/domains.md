# Domains

Where the base domain is declared, how each plane reads it, and what to re-apply when it changes.

One base domain, one file: `config/sops/cluster.sops.yaml`, a SOPS-encrypted Secret whose three
relevant keys are:

| Key            | Is                                     | Example host                 |
| -------------- | -------------------------------------- | ---------------------------- |
| `DOMAIN`       | the base domain                        | `auth.$DOMAIN`               |
| `SUB_INTERNAL` | label for mesh-only services           | `dash.$SUB_INTERNAL.$DOMAIN` |
| `SUB_NODES`    | label NetBird answers peer names under | `kenaz.$SUB_NODES.$DOMAIN`   |

The labels are bare (`in`, `n`), not domains: a consumer always composes
`$SUB_INTERNAL.$DOMAIN`. Nothing else in the repo spells a domain out. Never hardcode one in an
app.

## Reading it

**Flux.** `infra/substitutions` publishes the Secret as `cluster-values`. A consumer declares the
dependency and the source in its `ks.yaml`, then uses `${DOMAIN}` and `${SUB_INTERNAL}`
directly in its manifests:

```yaml
spec:
  dependsOn:
    - name: substitutions
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cluster-values
```

`infra/monitoring/ks.yaml` is the reference implementation. `dependsOn` names the Kustomization
that publishes the values, and `substituteFrom` names the object this manifest reads.

`replacements` is not used for domains. It rewrites one delimiter-separated segment of a field,
which cannot reach a domain sitting mid-string. An OIDC discovery URL has a path after the host.
Mixing both mechanisms would also mean two ways to spell one value.

**Tofu.** `bunny`, `oidc` and `netbird` each declare the keys they need in their `refs.env`,
and `sops --extract` them at plan time. No module keeps a copy. See
[Values another plane owns](../tofu/index.md#values-another-plane-owns).

**Ansible.** `just ans render-secrets` decrypts the same file into
`ansible/.generated/cluster.yml`, and `inventory/group_vars/all/dns.yml` gives it a nested shape.
Use `{{ dns.domain }}`, `{{ dns.sub.nodes }}` and `{{ dns.sub.internal }}`. The flat capitals
exist only because a Kubernetes Secret cannot nest.

## Changing the domain

Edit the one file, then re-apply everything that resolved it:

```bash
just ops sops config/sops/cluster.sops.yaml
just tf apply bunny
just tf apply netbird
just tf apply oidc
just ans setup
```

`netbird` moves the peer domain, so every node's `ansible_host` changes with it. Ansible reaches
the nodes by mesh name.

`just tf apply netbird` here changes `netbird_account_settings`, which needs the policy service
user promoted to Admin for the duration. See
[Applying account settings](../tofu/netbird.md#applying-account-settings).

Verify: `just fx failing` is empty, `just ks certs` shows every certificate `Ready` under the new
domain, and `just ops mesh` still resolves.

## Internal ingresses are unauthenticated by default

An `internal`-class `Ingress` is reachable by anything on the mesh, with no login in front of it.
That is still the default, and it is what `metrics.$SUB_INTERNAL.$DOMAIN` and
`logs.$SUB_INTERNAL.$DOMAIN` rely on today. Mesh membership is their only access control.

There are three ways an internal host gets a login, in order of preference.

**The app speaks OIDC.** Best case, and no proxy is involved. Register a client in `tofu/oidc`
and point the app at Pocket ID. Grafana does this through `auth.generic_oauth`, mapping the
`administrators` and `users` groups to Admin and Viewer. Actual does it too. Only this option can
express per-user roles, because only the app knows what a role means.

**The SSO middleware.** For an app with no OIDC support, add `auth-sso@kubernetescrd` to the
Ingress after the namespace's own rate limit:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: <namespace>-ratelimit@kubernetescrd,auth-sso@kubernetescrd
```

That is a Traefik `forwardAuth` pointing at the oauth2-proxy in `infra/auth`, which is registered
with Pocket ID as one shared client. `infra/glance` is the reference implementation. The gate is
binary: anyone in `administrators` or `users` gets in, and the app behind it sees no roles. The
session cookie is scoped to `.$SUB_INTERNAL.$DOMAIN`, so one login covers every host that opts
in. See [Cluster infrastructure](../gitops/infra.md#auth).

**Neither.** Mesh membership only, which is a deliberate choice for a host whose readers are
already trusted with the mesh.

Cross-namespace `Middleware` references work because `infra/traefik-internal` sets
`allowCrossNamespace: true` on its Kubernetes CRD provider.

## One thing that will bite you

In a plain manifest reconciled by a Flux `Kustomization`, escape a literal `$` as `$$`, or
envsubst will eat it. Both files under `infra/storage/app/storageclass-*.yaml` do this for
rclone's own `${pvc.metadata.*}` template variables.
