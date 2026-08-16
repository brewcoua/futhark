import '_kube.just'

# List this module's recipes
help:
    @just --list bak

# List backup schedules and the jobs they most recently produced
schedules:
    kubectl get schedules.k8up.io -A

# The same three values infra/backup/app/secret.yaml syncs for the operator, plus the bucket and
# endpoint it was rendered with, as shell exports for `eval`. Read back off the cluster so no
# recipe here can disagree with what actually wrote the snapshots.
_repo-env:
    #!/usr/bin/env bash
    set -euo pipefail

    creds=$(kubectl -n k8up get secret k8up-b2 -o json)
    env=$(kubectl -n k8up get deployment -o jsonpath='{.items[0].spec.template.spec.containers[0].env}')
    bucket=$(jq -r '.[] | select(.name=="BACKUP_GLOBALS3BUCKET") | .value' <<<"$env")
    endpoint=$(jq -r '.[] | select(.name=="BACKUP_GLOBALS3ENDPOINT") | .value' <<<"$env")

    printf 'export RESTIC_PASSWORD=%q\n' "$(jq -r '.data.RESTIC_PASSWORD | @base64d' <<<"$creds")"
    printf 'export AWS_ACCESS_KEY_ID=%q\n' "$(jq -r '.data.B2_KEY_ID | @base64d' <<<"$creds")"
    printf 'export AWS_SECRET_ACCESS_KEY=%q\n' "$(jq -r '.data.B2_APPLICATION_KEY | @base64d' <<<"$creds")"
    printf 'export RESTIC_REPOSITORY=%q\n' "s3:$endpoint/$bucket"

# List every restic snapshot in the repository, with the volume each one holds and its size
snapshots:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just bak _repo-env)"

    # The size is not in the Snapshot CRD: K8up copies only the id, date and paths off restic.
    # It comes from the snapshot's own summary, which restic wrote at backup time, so the whole
    # list costs one call rather than a `restic stats` per snapshot. A snapshot taken by a restic
    # older than 0.17 carries no summary and lands here with an empty size.
    sizes=$(restic snapshots --json \
      | jq -r '.[] | [.id, (.summary.total_bytes_processed // "")] | @tsv')

    kubectl get snapshots.k8up.io -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.spec.id}{"\t"}{.spec.date}{"\t"}{.spec.paths[0]}{"\n"}{end}' \
      | awk -F'\t' -v OFS='\t' 'NR==FNR {s[$1]=$2; next} {print $1, $2, $3, $4, ($2 in s ? s[$2] : "")}' \
        <(echo "$sizes") - \
      | numfmt -d $'\t' --to=iec --field=5 --invalid=ignore \
      | column -t -s $'\t' -N NAMESPACE,ID,DATE,PATH,SIZE

# Depth counts from the volume the snapshot holds rather than from /, so the default shows that
# volume's contents and one level under it.
#
# Look inside a snapshot without restoring it, `eza -T -L<depth>` style
ls id depth="2":
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just bak _repo-env)"

    # A restic snapshot holds exactly one path, and `restic ls` walks the whole tree under it
    # with no depth flag of its own — the depth is a filter on the paths it prints, counted
    # against the snapshot's own root rather than against /.
    base=$(restic snapshots --json "{{ id }}" | jq -r '.[0].paths[0]')
    [ -n "$base" ] && [ "$base" != "null" ] \
      || { echo "no snapshot '{{ id }}' in the repository (see: just bak snapshots)" >&2; exit 1; }

    restic ls -l "{{ id }}" \
      | awk -v base="$base" -v d='{{ depth }}' '
          BEGIN { root = base; sub(/\/+$/, "", root); b = gsub(/\//, "/", root) }
          length($1) >= 10 && $1 ~ /^[-dlbcps]/ {
            p = substr($0, index($0, "/"))
            n = gsub(/\//, "/", p) - b
            if (n >= 1 && n <= d) printf "%10s  %*s%s\n", $4, 2 * (n - 1), "", p
          }' \
      | numfmt --to=iec --field=1 --invalid=ignore

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

# restic directly, not a k8up Restore CR. K8up cannot restore what it took from stdin: "You can't
# restore from backups that were done from stdin (PreBackupPod or backup command annotation)",
# and this namespace's snapshot is exactly that. Its own documentation sends you to `restic dump`.
#
# Credentials come out of the cluster rather than out of Infisical by hand, so there is one
# procedure rather than two. `just bak restore postgres` is not it and never will be: that recipe
# restores local-path PVCs.
#
# Write the PostgreSQL dump to a local file. Reads only, so this is how a restore gets rehearsed
pg-dump id="" out="":
    #!/usr/bin/env bash
    set -euo pipefail

    snap="{{ id }}"
    path=""
    if [ -n "$snap" ]; then
      path=$(kubectl -n postgres get snapshots.k8up.io -o \
        "jsonpath={range .items[?(@.spec.id=='$snap')]}{.spec.paths[0]}{end}")
    else
      read -r snap path < <(kubectl -n postgres get snapshots.k8up.io \
        -o 'jsonpath={range .items[*]}{.spec.date}{"\t"}{.spec.id}{"\t"}{.spec.paths[0]}{"\n"}{end}' \
        | grep '\.sql$' | sort | tail -1 | cut -f2,3 | tr '\t' ' ')
    fi
    [ -n "$snap" ] && [ -n "$path" ] \
      || { echo "no .sql snapshot in the postgres namespace (see: just bak snapshots)" >&2; exit 1; }

    out="{{ out }}"
    [ -n "$out" ] || out=".tmp/postgres-$(date +%Y%m%dT%H%M%S).sql"
    mkdir -p "$(dirname "$out")"

    eval "$(just bak _repo-env)"

    restic dump "$snap" "$path" > "$out"
    echo
    ls -lh "$out"
    echo
    echo "read it:    head -40 $out"
    echo "replay it:  just bak pg-restore"

# Gated on typing the namespace back rather than on [confirm], for the same reason as `restore`
# below: pg_dumpall --clean drops and recreates every database and role in the dump, so anything
# written since the snapshot is gone.
#
# Replay the dump into the live PostgreSQL, OVERWRITING every database in it
pg-restore id="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Through the same recipe an operator would run by hand, and to a file rather than a pipe, so
    # what was applied is still on disk afterwards if the replay goes wrong.
    dump=".tmp/postgres-restore-$(date +%Y%m%dT%H%M%S).sql"
    just bak pg-dump "{{ id }}" "$dump" > /dev/null

    # The primary, by the role label CloudNativePG maintains. Replaying over the local socket is
    # what makes this work at all: the cluster runs with enableSuperuserAccess: false, so there
    # is no superuser password anywhere and peer authentication inside the pod is the only way
    # in as postgres.
    primary=$(kubectl -n postgres get pod -l cnpg.io/cluster=postgres,role=primary -o name | head -1)
    [ -n "$primary" ] || { echo "no primary pod in the postgres cluster" >&2; exit 1; }

    # Who the tenants are is not guessed and not listed here: it is the set of namespaces the
    # policy overlay opens port 5432 to, which is the same declaration that lets them connect at
    # all. A tenant that cannot reach the database cannot be writing to it.
    tenants=$(kubectl -n postgres get networkpolicy \
      -o 'jsonpath={range .items[*]}{range .spec.ingress[?(@.ports[0].port==5432)]}{range .from[*]}{.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name}{"\n"}{end}{end}{end}' \
      | grep -v '^cnpg-system$' | grep -v '^$' | sort -u)

    # Flux scales them straight back up once these resume, so the replica counts are never
    # written down anywhere. Both owners, for the same reason as `restore` below: a
    # chart-created workload (every one in monitoring) appears in no Kustomization inventory at
    # all, only in the release, and suspending the wrong owner means nothing scales it back.
    ks=""
    hr=""
    for ns in $tenants; do
      ks="$ks $(kubectl -n flux-system get kustomization \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .status.inventory.entries[*]}{.id}{" "}{end}{"\n"}{end}' \
        | awk -v ns="$ns" 'index($0, "\t" ns "_") || index($0, " " ns "_") {print $1}')"
      hr="$hr $(kubectl -n flux-system get helmrelease \
        -o "jsonpath={range .items[?(@.spec.targetNamespace=='$ns')]}{.metadata.name}{' '}{end}")"
    done

    echo
    echo "replaying $dump into $primary."
    echo
    echo "  every database and role below is DROPPED and recreated from the dump:"
    kubectl -n postgres get database.postgresql.cnpg.io -o name | sed 's/^/    /'
    echo
    echo "  scaled to zero for the replay, then resumed:"
    echo "$tenants" | sed 's/^/    ns\//'
    echo
    printf "type the namespace to confirm: "
    read -r confirm
    [ "$confirm" = "postgres" ] || { echo "aborted. the dump is still at $dump" >&2; exit 1; }

    # Resuming is a trap rather than a line at the end. Everything below can fail with the
    # tenants already suspended and at zero replicas, and a failure has to degrade to "the
    # restore did not happen" rather than to "the cluster is off". Flux puts every replica count
    # back from git on resume.
    #
    # A HelmRelease needs the --force on top of the resume: `kubectl scale` is cluster drift, not
    # release drift, so helm-controller reconciles a resumed release as already up to date and
    # leaves the replica counts at zero. --force re-runs the upgrade, which re-applies them.
    resume() {
      for h in $hr; do
        flux resume helmrelease "$h" -n flux-system > /dev/null || true
        flux reconcile helmrelease "$h" -n flux-system --force > /dev/null || true
      done
      for k in $ks; do flux resume kustomization "$k" > /dev/null || true; done
    }
    trap resume EXIT

    for k in $ks; do flux suspend kustomization "$k"; done
    for h in $hr; do flux suspend helmrelease "$h" -n flux-system; done
    for ns in $tenants; do
      kubectl -n "$ns" scale deployment,statefulset --all --replicas=0
      # Not `pod --all`: the scale above does not touch a DaemonSet, so its pods stay Running
      # and waiting on them spends the whole timeout before failing. monitoring runs two,
      # node-exporter and fluent-bit, and neither holds a database connection.
      pods=$(kubectl -n "$ns" get pod -o json \
        | jq -r '.items[] | select((.metadata.ownerReferences // [])[0].kind != "DaemonSet") | .metadata.name')
      if [ -n "$pods" ]; then
        kubectl -n "$ns" wait --for=delete pod $pods --timeout=5m
      fi
    done

    kubectl -n postgres exec -i "$primary" -c postgres -- psql -U postgres < "$dump"

    resume
    trap - EXIT
    echo
    echo "replayed and resumed, from $dump. verify each tenant shows its own data, then: just fx failing"

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
