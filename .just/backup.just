import '_kube.just'

# List this module's recipes
help:
    @just --list bak

# List backup schedules and the jobs they most recently produced
schedules:
    kubectl get schedules.k8up.io -A

# List every restic snapshot in the repository, with the volume each one holds
snapshots:
    kubectl get snapshots.k8up.io -A \
      -o 'custom-columns=NAMESPACE:.metadata.namespace,ID:.spec.id,DATE:.spec.date,PATH:.spec.paths[0]'

# List the backup, check and prune jobs K8up has run, newest last
jobs:
    kubectl get jobs -A -l k8up.io/owned-by --sort-by=.metadata.creationTimestamp

# Show a job's log, including restic's summary of what it actually copied
logs job namespace:
    kubectl -n {{ namespace }} logs job/{{ job }}

# Back up a namespace immediately instead of waiting for 03:00
now ns:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl -n {{ ns }} create -f - <<'EOF'
    apiVersion: k8up.io/v1
    kind: Backup
    metadata:
      generateName: manual-
    spec:
      failedJobsHistoryLimit: 3
      successfulJobsHistoryLimit: 1
    EOF

# Restore a namespace's local-path volumes from the repository, WIPING them first. The snapshot
# defaults to the newest one for each volume; the rclone-backed classes are left alone.
#
# Deliberately not reachable from any aggregate recipe, and gated on typing the namespace back
# rather than on [confirm]: this deletes PVCs, and the operator should have to look at the list
# of which ones before it happens.
restore ns:
    #!/usr/bin/env bash
    set -euo pipefail

    kubectl get namespace "{{ ns }}" > /dev/null

    wipe=$(kubectl -n "{{ ns }}" get pvc \
      -o 'jsonpath={range .items[?(@.spec.storageClassName=="local-path")]}{.metadata.name}{"\n"}{end}')
    keep=$(kubectl -n "{{ ns }}" get pvc \
      -o 'jsonpath={range .items[*]}{.metadata.name}{" ("}{.spec.storageClassName}{")\n"}{end}' \
      | grep -v '(local-path)$' || true)
    [ -n "$wipe" ] || { echo "no local-path PVCs in '{{ ns }}' — nothing this restore would replace" >&2; exit 1; }

    # Flux recreates a deleted PVC within its reconcile interval, which races the restore and
    # wins often enough to matter. Two controllers can do it, so both get suspended: the
    # Kustomization, whose inventory entry ids are <namespace>_<name>_<group>_<kind>, and any
    # HelmRelease targeting the namespace — a chart-created PVC (Grafana's) appears in no
    # Kustomization inventory at all, only in the release.
    #
    # Every Kustomization owning anything here, not just the app's: infra-policies puts a
    # NetworkPolicy in every namespace, and picking one owner would mean guessing which.
    # Suspending a policy overlay for the length of a restore costs nothing.
    ks=$(kubectl -n flux-system get kustomization \
      -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .status.inventory.entries[*]}{.id}{" "}{end}{"\n"}{end}' \
      | awk -v ns="{{ ns }}" 'index($0, "\t" ns "_") || index($0, " " ns "_") {print $1}')
    hr=$(kubectl -n flux-system get helmrelease \
      -o "jsonpath={range .items[?(@.spec.targetNamespace=='{{ ns }}')]}{.metadata.name}{'\n'}{end}")
    [ -n "$ks$hr" ] || { echo "nothing in Flux owns namespace '{{ ns }}' (see: just fx get)" >&2; exit 1; }

    echo
    echo "restoring namespace '{{ ns }}' from the newest snapshot of each volume."
    echo "  suspending:" $ks $hr
    echo
    echo "  DELETED and recreated from the repository:"
    echo "$wipe" | sed 's/^/    pvc\//'
    if [ -n "$keep" ]; then
      echo "  left alone:"
      echo "$keep" | sed 's/^/    pvc\//'
    fi
    echo
    printf "type the namespace to confirm: "
    read -r confirm
    [ "$confirm" = "{{ ns }}" ] || { echo "aborted." >&2; exit 1; }

    for k in $ks; do flux suspend kustomization "$k"; done
    for h in $hr; do flux suspend helmrelease "$h" -n flux-system; done

    # A PVC with a running pod on it stays Terminating forever. Scale to zero rather than
    # delete: resuming below is what puts the replica counts back.
    kubectl -n "{{ ns }}" scale deployment,statefulset --all --replicas=0
    kubectl -n "{{ ns }}" wait --for=delete pod --all --timeout=5m

    # Recreate each PVC from its own live spec rather than letting Flux do it. K8up restores into
    # an existing claim, and resuming Flux to get one back would also scale the workloads up
    # again — straight onto a volume that is still empty.
    for pvc in $wipe; do
      spec=$(kubectl -n "{{ ns }}" get pvc "$pvc" -o json \
        | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
                  .metadata.annotations["pv.kubernetes.io/bind-completed"],
                  .metadata.annotations["pv.kubernetes.io/bound-by-controller"],
                  .metadata.annotations["volume.kubernetes.io/selected-node"],
                  .metadata.finalizers, .spec.volumeName, .status)')
      kubectl -n "{{ ns }}" delete pvc "$pvc"
      echo "$spec" | kubectl apply -f -
    done

    # One Restore per volume: a restic snapshot holds exactly one path, so there is no snapshot
    # that carries a whole namespace. Without spec.snapshot K8up takes the newest one whose
    # paths match, which is why spec.paths is set — it is the only thing stopping a restore of
    # `grafana` from silently landing another volume's contents.
    for pvc in $wipe; do
      kubectl -n "{{ ns }}" create -f - <<EOF
    apiVersion: k8up.io/v1
    kind: Restore
    metadata:
      generateName: restore-$pvc-
    spec:
      paths: ["/data/$pvc"]
      restoreMethod:
        folder:
          claimName: $pvc
    EOF
    done

    kubectl -n "{{ ns }}" wait --for=condition=complete job -l k8up.io/owned-by --timeout=30m

    for h in $hr; do flux resume helmrelease "$h" -n flux-system; done
    for k in $ks; do flux resume kustomization "$k"; done
    echo
    echo "restored. verify the app, then check: just bak jobs"
