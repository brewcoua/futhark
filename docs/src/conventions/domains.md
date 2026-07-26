# Domains

Base domains live in exactly one file, `config/domain/domain.env`, as `DOMAIN` and
`INT_DOMAIN`. Ansible reads the same file through
`ansible/inventory/group_vars/all.yml`. Never hardcode a base domain in an app.

`config/domain/kustomization.yaml` wraps it as a reusable Kustomize Component that generates
a `domain` ConfigMap. It lives under `config/` rather than `infra/` precisely because it is
not infra-only.

Flux's `postBuild.substitute` and `substituteFrom` cannot reach `HelmRelease.spec.values`, so
domain injection goes through plain kustomize instead. An `app/` that needs a hostname adds
the component and a `replacements` block splicing a key into the target field:

```yaml
components:
  - ../../../config/domain
replacements:
  - source:
      kind: ConfigMap
      name: domain
      fieldPath: data.INT_DOMAIN
    targets: [...]
```

`infra/monitoring/app/kustomization.yaml` is the reference implementation.

Two things that will bite you:

- A Component cannot set a top-level `namespace:` — that field is reserved to the root
  Kustomization — so the generated ConfigMap would carry none and fail to apply. It is
  patched into `flux-system` once, inside `config/domain/kustomization.yaml`, because every
  consumer needs it there regardless of its own target namespace.
- In a plain manifest reconciled by a Flux `Kustomization`, escape a literal `$` as `$$`, or
  envsubst will eat it. `infra/storage/app/storageclass.yaml` does this for rclone's own
  `${pvc.metadata.*}` template variables.
