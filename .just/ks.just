import '_kube.just'

# One-screen health report — nodes, unhealthy pods, Flux sync state
status:
    kubectl get nodes -o wide
    @just ks failing
    @just fx get

# List cluster nodes
nodes:
    kubectl get nodes -o wide

# List pods, in one namespace or all of them
pods ns='':
    kubectl get pods {{ if ns == '' { '-A' } else { '-n ' + ns } }}

# List only pods that aren't Running/Completed with all containers ready
failing:
    #!/usr/bin/env bash
    set -euo pipefail
    # READY is "n/m". A finished pod always reads 0/m, so judge it by STATUS alone;
    # everything else has to be Running with every container ready.
    kubectl get pods -A -o wide --no-headers | awk '
      $4 == "Completed" { next }
      { split($3, r, "/") }
      r[1] != r[2] || $4 != "Running"
    ' | grep . || echo "all pods healthy"

# Show recent events, in one namespace or all of them
events ns='':
    kubectl get events --sort-by=.lastTimestamp {{ if ns == '' { '-A' } else { '-n ' + ns } }}

# Show recent Warning events only, in one namespace or all of them
warnings ns='':
    kubectl get events --field-selector=type=Warning --sort-by=.lastTimestamp {{ if ns == '' { '-A' } else { '-n ' + ns } }}

# Follow a workload's logs (name may be deploy/x, job/x, or a pod)
logs ns name:
    kubectl -n {{ ns }} logs {{ name }} --tail=200 --all-containers --follow

# Show a crashed pod's logs from before its last restart
previous ns pod:
    kubectl -n {{ ns }} logs {{ pod }} --previous --tail=200 --all-containers

# Describe a pod, with its events
describe ns pod:
    kubectl -n {{ ns }} describe pod {{ pod }}

# Roll a Deployment and wait for it
restart ns deploy:
    kubectl -n {{ ns }} rollout restart deploy/{{ deploy }}
    kubectl -n {{ ns }} rollout status deploy/{{ deploy }}

# List Jobs and CronJobs, in one namespace or all of them
jobs ns='':
    kubectl get jobs {{ if ns == '' { '-A' } else { '-n ' + ns } }}
    kubectl get cronjobs {{ if ns == '' { '-A' } else { '-n ' + ns } }}

# Delete finished (Complete or Failed) Jobs; running Jobs are left alone
jobs-clean ns='':
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl get jobs {{ if ns == '' { '-A' } else { '-n ' + ns } }} \
      -o 'jsonpath={range .items[*]}{.metadata.namespace} {.metadata.name} {.status.active}{"\n"}{end}' \
    | awk '$3 == "" || $3 == "0" { print $1, $2 }' \
    | while read -r js job; do
        kubectl -n "$js" delete job "$job"
      done
    echo "no finished Jobs left."

# Show real CPU/memory usage per node, and the 15 hungriest pods
top:
    kubectl top nodes
    kubectl top pods -A --sort-by=memory | head -16

# List Ingresses across all namespaces
ingress:
    kubectl get ingress -A

# List Certificates and pending CertificateRequests
certs:
    kubectl get certificate,certificaterequest -A

# kubectl passthrough using the generated kubeconfig
[positional-arguments]
kctl *args:
    kubectl "$@"
