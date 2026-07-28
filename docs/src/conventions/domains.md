# Domains

Two base domains, two different mechanisms — pick the one that matches which one you need.

## DOMAIN (edge)

Lives in `config/domain/domain.env`, cleartext, as `DOMAIN`. Never hardcode it in an app.

`config/domain/kustomization.yaml` wraps it as a reusable Kustomize Component that generates
a `domain` ConfigMap. It lives under `config/` rather than `infra/` because it isn't infra-only
in spirit (it's the one base value every edge-facing app needs), even though nothing outside
Flux currently reads the file.

An `app/` that needs an edge hostname adds the component and a `replacements` block splicing
`data.DOMAIN` into the target field:

```yaml
components:
  - ../../../config/domain
replacements:
  - source:
      kind: ConfigMap
      name: domain
      fieldPath: data.DOMAIN
    targets: [...]
```

`infra/auth/app/kustomization.yaml` is the reference implementation.

A replacement rewrites one delimiter-separated _segment_ of a field, which covers a bare
hostname but not a domain sitting mid-string — an OIDC discovery URL has a path after the host,
so there is no single segment to swap. For those, `infra/substitutions` publishes the same
`domain` ConfigMap as a dependency-free Kustomization, and the consumer uses `${DOMAIN}`:

```yaml
spec:
  dependsOn:
    - name: substitutions
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: domain
```

`nodes/kenaz.k0s/actual/` is the reference implementation. Reach for `replacements` first;
`${DOMAIN}` only where the value is embedded in a longer string.

## INT_DOMAIN (internal)

Lives SOPS-encrypted in `infra/substitutions/app/int-domain.sops.yaml`, a Secret with the key
`INT_DOMAIN`, reconciled by the dependency-free `substitutions` Kustomization along with every
other substitution source — it must land before any consumer does, so the Secret already exists
when `postBuild.substituteFrom` runs.

A consumer declares the dependency and substitution source in its own `ks.yaml`:

```yaml
spec:
  dependsOn:
    - name: substitutions
  postBuild:
    substituteFrom:
      - kind: Secret
        name: int-domain
```

`dependsOn` names the Kustomization that publishes the values; `substituteFrom` names the
individual object this manifest reads.

and references `${INT_DOMAIN}` directly in its manifests — no `replacements` block needed,
`postBuild.substituteFrom` reaches `HelmRelease.spec.values` fine (see
`infra/traefik-edge/app/helmrelease.yaml`'s `${PUBLIC_IP}`/`${MESH_IP}`). `infra/monitoring/ks.yaml`
and `infra/monitoring/app/{grafana,headlamp,vlsingle,vmsingle}.yaml` are the reference
implementation.

Tofu needs the same value for the Bunny DNS wildcard record (`tofu/bunny/dns.tf`), and
`tofu/oidc` for its internal redirect URIs. Neither keeps a copy: both declare it in their
`refs.env` and `sops --extract` it out of this same file at plan/apply time. See
[Values another plane owns](../tofu/index.md#values-another-plane-owns).

## Two things that will bite you

- A Kustomize Component cannot set a top-level `namespace:` — that field is reserved to the
  root Kustomization — so a Component-generated resource would carry none and fail to apply.
  `config/domain/kustomization.yaml` patches `flux-system` in once, since every consumer needs
  it there regardless of its own target namespace.
- In a plain manifest reconciled by a Flux `Kustomization`, escape a literal `$` as `$$`, or
  envsubst will eat it. `infra/storage/app/storageclass.yaml` does this for rclone's own
  `${pvc.metadata.*}` template variables.
