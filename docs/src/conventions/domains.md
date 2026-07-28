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

## INT_DOMAIN (internal)

Lives SOPS-encrypted in `infra/int-domain/app/int-domain.sops.yaml` (a Secret, key
`INT_DOMAIN`), its own Flux Kustomization (`infra/int-domain/ks.yaml`) with no dependencies —
same reasoning as `infra/edge-ips`: it must reconcile before any consumer does, so the Secret
already exists when `postBuild.substituteFrom` runs.

A consumer declares the dependency and substitution source in its own `ks.yaml`:

```yaml
spec:
  dependsOn:
    - name: int-domain
  postBuild:
    substituteFrom:
      - kind: Secret
        name: int-domain
```

and references `${INT_DOMAIN}` directly in its manifests — no `replacements` block needed,
`postBuild.substituteFrom` reaches `HelmRelease.spec.values` fine (see
`infra/traefik-edge/app/helmrelease.yaml`'s `${PUBLIC_IP}`/`${MESH_IP}`). `infra/monitoring/ks.yaml`
and `infra/monitoring/app/{grafana,headlamp,vlsingle,vmsingle}.yaml` are the reference
implementation.

Tofu needs the same value for the Bunny DNS wildcard record (`tofu/bunny/dns.tf`) but can't
read a Flux-side Secret, so it's duplicated as `TF_VAR_int_domain` in
`tofu/bunny/secrets.sops.env` — change both together.

## Two things that will bite you

- A Kustomize Component cannot set a top-level `namespace:` — that field is reserved to the
  root Kustomization — so a Component-generated resource would carry none and fail to apply.
  `config/domain/kustomization.yaml` patches `flux-system` in once, since every consumer needs
  it there regardless of its own target namespace.
- In a plain manifest reconciled by a Flux `Kustomization`, escape a literal `$` as `$$`, or
  envsubst will eat it. `infra/storage/app/storageclass.yaml` does this for rclone's own
  `${pvc.metadata.*}` template variables.
