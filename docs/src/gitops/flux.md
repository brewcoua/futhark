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

Run by `task ans:k0s` (`ansible/playbooks/k0s.yml`):

1. **`k0s_cluster`** — render `k0sctl.yaml` from inventory, `k0sctl apply`, fetch the
   kubeconfig into `ansible/.generated/`.
2. **`local_path_provisioner`** — install the `local-path` StorageClass. OpenBao's
   StatefulSet needs it to bind its PVC on the very first reconcile, and nothing in the
   Flux-managed tree can provision it, since OpenBao is the root of that graph.
3. **`openbao`'s `prep.yml`** — create the `openbao` Namespace and the seal Secret (KMIP
   endpoint, key id, mTLS material, all from Proton Pass) _before_ Flux exists.
   `infra/openbao`'s StatefulSet needs both mounted on its first reconcile. See
   [Startup ordering](../conventions/ordering.md).
4. **`flux_bootstrap`**:
   1. Install the Flux Operator via Helm.
   2. Apply the `flux-system/git-deploy-key` Secret, with `known_hosts` built from GitHub's
      published host keys rather than a blind `ssh-keyscan`.
   3. Wait for the Flux Operator to be ready.
   4. Push the `edge-ips` ConfigMap — the public-ingress node's public and mesh addresses,
      straight into the cluster and never into git. See
      [Secrets](../conventions/secrets.md).
   5. Apply `flux/cluster.yaml`. Flux takes over from here, reconciling `openbao` first and
      everything else behind it.

Once OpenBao is up and auto-unsealed, run `task bao:policy-sync` to finish the
namespace, mount, auth and policy bootstrap. It is idempotent and safe to re-run. It is not
part of the automated sequence above because it needs the OpenBao pod already running.

## Day-to-day

```bash
task fx:get        # every Kustomization and its sync status
task fx:failing    # only what isn't Ready
task fx:reconcile  # force-reconcile everything, or `-- <name>` for one
task fx:logs       # tail kustomize-controller
```

The full list is in [Task reference](../operations/tasks.md).
