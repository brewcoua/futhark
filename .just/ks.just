import '_kube.just'

# List this module's recipes
help:
    @just --list ks

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

# auth-dir is a ReadWriteOnce volume the running Deployment holds, so the login pod can only mount
# it once the Deployment has let go. The trap is the reason this is a recipe: an abandoned flow
# still owes a scale-up. Interactive, so it holds the terminal until Ctrl-C. See
# docs/src/operations/cli-proxy-login.md.

# Link a subscription account into cli-proxy-api (claude, codex, antigravity)
cli-proxy-login provider='claude':
    #!/usr/bin/env bash
    set -euo pipefail
    ns=cli-proxy-api
    # Each vendor fixes its own callback port, which the port-forward has to match.
    case '{{ provider }}' in
      claude)      port=54545 ;;
      codex)       port=1455  ;;
      antigravity) port=51121 ;;
      *) echo "unknown provider '{{ provider }}': use claude, codex or antigravity" >&2; exit 1 ;;
    esac
    # Both read off the Deployment rather than written here. The image so the login never runs a
    # different build from the server, the ConfigMap because its name carries a content hash.
    image=$(kubectl -n "$ns" get deploy/cli-proxy-api -o jsonpath='{.spec.template.spec.containers[0].image}')
    cm=$(kubectl -n "$ns" get deploy/cli-proxy-api -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')
    cleanup() {
      echo
      echo "cleaning up: removing the login pod and restoring the replica"
      kubectl -n "$ns" delete pod cli-proxy-login --ignore-not-found --now >/dev/null
      kubectl -n "$ns" scale deployment/cli-proxy-api --replicas=1 >/dev/null
      kubectl -n "$ns" rollout status deployment/cli-proxy-api --timeout=120s
    }
    trap cleanup EXIT
    kubectl -n "$ns" scale deployment/cli-proxy-api --replicas=0
    kubectl -n "$ns" rollout status deployment/cli-proxy-api --timeout=60s
    # The ConfigMap comes along so the login writes to the same auth-dir the server reads.
    kubectl -n "$ns" run cli-proxy-login --image="$image" --restart=Never --overrides='{
      "spec": {
        "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
        "containers": [{
          "name": "cli-proxy-login",
          "image": "'"$image"'",
          "args": ["/CLIProxyAPI/CLIProxyAPI", "--{{ provider }}-login"],
          "stdin": true,
          "tty": true,
          "volumeMounts": [
            {"name": "auth", "mountPath": "/data"},
            {"name": "config", "mountPath": "/CLIProxyAPI/config.yaml", "subPath": "config.yaml"}
          ]
        }],
        "volumes": [
          {"name": "auth", "persistentVolumeClaim": {"claimName": "cli-proxy-api-auth"}},
          {"name": "config", "configMap": {"name": "'"$cm"'"}}
        ]
      }
    }'
    kubectl -n "$ns" wait --for=condition=Ready pod/cli-proxy-login --timeout=120s
    kubectl -n "$ns" port-forward pod/cli-proxy-login "$port:$port" >/dev/null &
    echo
    echo "open the URL below, sign in, then press Ctrl-C once the log reports success"
    echo
    kubectl -n "$ns" logs -f cli-proxy-login

# kubectl passthrough using the generated kubeconfig
[positional-arguments]
kctl *args:
    kubectl "$@"
