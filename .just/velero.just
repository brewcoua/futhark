import '_kube.just'

# List backups and their status
backups:
    velero backup get

# List past restores and their status
restores:
    velero restore get

# List backup schedules and when each last ran
schedules:
    velero schedule get

# Show a backup's contents, including which volumes it actually copied
describe backup:
    velero backup describe {{ backup }} --details

# Show a backup's log
logs backup:
    velero backup logs {{ backup }}

# Run the daily schedule immediately instead of waiting for 03:00
now:
    velero backup create --from-schedule daily --wait

# Restore a namespace's local-path volumes from a backup, WIPING them first. The backup defaults
# to the newest completed one; storagebox-crypt volumes are left alone.
#
# Deliberately not reachable from any aggregate recipe, and gated on typing the namespace back
# rather than on [confirm]: this deletes PVCs, and the operator should have to look at the list
# of which ones before it happens.
restore ns backup='':
    #!/usr/bin/env bash
    set -euo pipefail
    backup="{{ backup }}"

    kubectl get namespace "{{ ns }}" > /dev/null

    # kubectl, not `velero backup get`, which only formats as table/json/yaml.
    if [ -z "$backup" ]; then
      backup=$(kubectl -n velero get backups.velero.io \
        -o 'jsonpath={range .items[?(@.status.phase=="Completed")]}{.status.startTimestamp}{" "}{.metadata.name}{"\n"}{end}' \
        | sort | awk 'END {print $2}')
      [ -n "$backup" ] || { echo "no Completed backup to restore from (see: just bak backups)" >&2; exit 1; }
    fi

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
    echo "restoring namespace '{{ ns }}' from backup '$backup'."
    echo "  suspending:" $ks $hr
    echo
    echo "  DELETED and recreated from the backup:"
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
    echo "$wipe" | xargs -r kubectl -n "{{ ns }}" delete pvc

    velero restore create --from-backup "$backup" --include-namespaces "{{ ns }}" \
      --existing-resource-policy=update --wait

    for h in $hr; do flux resume helmrelease "$h" -n flux-system; done
    for k in $ks; do flux resume kustomization "$k"; done
    echo
    echo "restored. verify the app, then check: just bak restores"
