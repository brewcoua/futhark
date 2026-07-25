# flux

GitOps entrypoint. `cluster.yaml` (the `FluxInstance` CR) is applied once by
`ansible/roles/flux_bootstrap` — Flux does not reconcile this directory itself, to avoid
watching its own bootstrap. Everything else under `flux/` (`infra/`, `nodes/`) IS
reconciled: each holds a `ks.yaml`, the Flux `Kustomization` CR that points Flux at the
matching repo-root directory (`../infra`, `../nodes`).

Cross-cutting conventions (naming, layout, namespaces, network policy, ESO RBAC, domains,
Flux boilerplate) live in [`CONVENTIONS.md`](../CONVENTIONS.md), not here. The one
exception: `flux/infra/ks.yaml` and `flux/nodes/ks.yaml` keep their full spec rather than
being patched like every other `ks.yaml`, because `flux/` has no `kustomization.yaml` of
its own to patch from — Flux auto-generates one from `cluster.yaml`'s `sync.path: flux`,
and adding a real one would pull `cluster.yaml` itself into reconciliation.

## Bootstrap sequence

Run by `task ans:k0s` (`ansible/playbooks/k0s.yml`):

1. `k0s_cluster` — `k0sctl apply`, fetch the kubeconfig.
2. `ansible/roles/openbao`'s `prep.yml` — create the `openbao` Namespace and the seal
   Secret (KMIP endpoint/key id/mTLS material, from Proton Pass), _before_ Flux exists.
   `infra/openbao`'s StatefulSet needs both mounted on its very first reconcile — see
   `CONVENTIONS.md`'s Startup ordering.
3. `flux_bootstrap`:
   1. Install the Flux Operator via Helm.
   2. Apply the `flux-system/git-deploy-key` Secret, resolved from Proton Pass.
   3. Wait for the Flux Operator to be ready.
   4. Apply `flux/cluster.yaml` — Flux takes over from here, reconciling `openbao` first
      and everything else behind it.

Once OpenBao is up and auto-unsealed, run `task bao:policy-sync` (`ansible/roles/openbao`'s
`main.yml`) to finish namespace/mount/auth/policy bootstrap — idempotent, safe to re-run,
not part of the automated sequence above because it needs the OpenBao pod already running.

## Phase 2

Apps land under `nodes/<hostname>.k0s/`, one directory per app, each with its own
`ks.yaml` + `app/` — see `nodes/README.md`.
