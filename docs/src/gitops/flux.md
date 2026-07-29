# Bootstrap and reconciliation

`flux/` is the GitOps entrypoint. `flux/cluster.yaml` — the `FluxInstance` CR — is applied
once by `ansible/roles/flux_bootstrap`, and Flux does not reconcile the `flux/` directory
itself, to avoid watching its own bootstrap.

Everything else under `flux/` **is** reconciled. `flux/infra/ks.yaml` and `flux/nodes/ks.yaml`
are the two Flux `Kustomization` CRs that point Flux at the matching repo-root directories,
`./infra` and `./nodes`. Those two keep their full spec rather than being patched like every
other `ks.yaml`, because `flux/` has no `kustomization.yaml` of its own — Flux auto-generates
one from `cluster.yaml`'s `sync.path: flux`, and adding a real one would pull `cluster.yaml`
itself into reconciliation. The rest of the naming and layout rules are in
[Layout and naming](../conventions/layout.md).

## Bootstrap sequence

Run by `just ans k0s` (`ansible/playbooks/k0s.yml`):

1. **`k0s_cluster`** — render `k0sctl.yaml` from inventory, `k0sctl apply`, fetch the
   kubeconfig into `ansible/.generated/`.
2. **`local_path_provisioner`** — install the `local-path` StorageClass. `monitoring`, `auth`
   and `nodes/kenaz.k0s/actual` all bind PVCs on their first reconcile, and nothing in the
   Flux-managed tree can provision a StorageClass for itself. See
   [Startup ordering](../conventions/ordering.md).
3. **`flux_bootstrap`**:
   1. Install the Flux Operator via Helm.
   2. Apply the `flux-system/git-deploy-key` Secret, with `known_hosts` built from GitHub's
      published host keys rather than a blind `ssh-keyscan`.
   3. Create the namespaces the next step writes into, since Flux does not exist yet to declare
      them. Flux takes ownership of all of them on its first reconcile.
   4. Apply the two Secrets that exist to seed what Flux resolves for itself, and so cannot
      come from Flux: `flux-system/sops-age` and `infisical-universal-auth` in each tier
      namespace. See [Secrets](../conventions/secrets.md#the-secrets-outside-gitops).
   5. Wait for the Flux Operator to be ready.
   6. Apply `flux/cluster.yaml`. Flux takes over from here.

There is no follow-up step. Everything past `flux/cluster.yaml` is Flux reconciling git. The
handoff, and the one line it never crosses back over:

```d2
direction: down

ansible: "ansible/playbooks/k0s.yml" {
  k0s: k0s_cluster\nk0sctl apply
  lpp: local_path_provisioner\nlocal-path StorageClass
  boot: flux_bootstrap {
    op: Flux Operator\n(Helm)
    seeds: "git-deploy-key, sops-age,\ninfisical-universal-auth"
    inst: "apply flux/cluster.yaml\n(FluxInstance)"
  }
  k0s -> lpp -> boot.op
  boot.op -> boot.seeds -> boot.inst
}

flux: Flux { style.stroke-width: 3 }
git: this repository

ansible.boot.inst -> flux: hands over
git -> flux: sync.path flux/
flux -> infra: "flux/infra/ks.yaml -> ./infra"
flux -> nodes: "flux/nodes/ks.yaml -> ./nodes"

cluster: "flux/cluster.yaml is applied, never reconciled —\nFlux would otherwise watch its own bootstrap" {
  style: { stroke-dash: 4; fill: transparent; stroke: "#888" }
}
```

Every Kustomization carries a `decryption` block naming `flux-system/sops-age`, patched in once
via `infra/kustomization.yaml` and `nodes/kustomization.yaml`. `flux/infra/ks.yaml` and
`flux/nodes/ks.yaml` state it in full for the same reason they state everything else in full.

## Day-to-day

```bash
just fx get        # every Kustomization and its sync status
just fx failing    # only what isn't Ready
just fx reconcile  # force-reconcile everything, or `<name>` for one
just fx logs       # tail kustomize-controller
```

The full list is in [Recipe reference](../operations/recipes.md).
