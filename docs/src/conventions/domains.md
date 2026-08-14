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

## Who resolves the internal subdomain

Two resolvers answer `$SUB_INTERNAL.$DOMAIN`, and they are configured in different planes.

**Your devices.** `tofu/netbird` publishes a wildcard A record in NetBird's own DNS zone, pointing
at the mesh address traefik-internal listens on. Its `distribution_groups` is the `admin` group, so
only the operator's peers receive it. The nodes join `node` and `k8s` and do not.

**Pods.** `infra/coredns` writes a `coredns-custom` ConfigMap holding a stub zone that answers the
same subdomain with the same address. Without it every internal hostname is NXDOMAIN inside the
cluster: k3s strips loopback resolvers out of the kubelet resolv.conf, so CoreDNS forwards to the
public Bunny zone, which holds nothing under the internal label. That is what broke every
healthcheck Glance ran against an internal host.

k3s's bundled Corefile ends with `import /etc/coredns/custom/*.server` and carries `reload`, so the
ConfigMap lands without restarting CoreDNS. Verify from any pod:

```bash
kubectl -n glance exec deploy/glance -- nslookup metrics.$SUB_INTERNAL.$DOMAIN
```

Expect the mesh address. If it is still NXDOMAIN after about 30 seconds, force the reload with
`kubectl -n kube-system rollout restart deploy/coredns`.

Both resolvers answer for every name under the subdomain, including ones with no Ingress behind
them. Such a name resolves and then fails at the Traefik router, not at DNS.

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
binary: anyone in `administrators` or `users` gets in. The session cookie is scoped to
`.$SUB_INTERNAL.$DOMAIN`, so one login covers every host that opts in. See
[Cluster infrastructure](../gitops/infra.md#auth).

An app behind that middleware can still tell who the reader is, without becoming an OIDC client
itself, by reading the `X-Auth-Request-*` headers the middleware forwards. `infra/copyparty` is
the reference implementation: it maps the `groups` header onto per-volume permissions. This is
weaker than the first option, because the app is trusting a header rather than a signed token, and
it only holds while the app is unreachable except through the middleware.

**Neither.** Mesh membership only, which is a deliberate choice for a host whose readers are
already trusted with the mesh.

Cross-namespace `Middleware` references work because `infra/traefik-internal` sets
`allowCrossNamespace: true` on its Kubernetes CRD provider.

## One thing that will bite you

In a plain manifest reconciled by a Flux `Kustomization`, escape a literal `$` as `$$`, or
envsubst will eat it. Both files under `infra/storage/app/storageclass-*.yaml` do this for
rclone's own `${pvc.metadata.*}` template variables.
