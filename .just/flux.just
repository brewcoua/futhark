import '_kube.just'

# List Kustomizations and their sync status
get:
    flux get kustomizations -A

# List GitRepository sources and their sync status
sources:
    flux get sources git -A

# List HelmReleases and their sync status
hr:
    flux get helmreleases -A

# List only Kustomizations and HelmReleases that aren't Ready
failing:
    flux get kustomizations -A --status-selector ready=false
    flux get helmreleases -A --status-selector ready=false

# Force a HelmRelease to reinstall/upgrade even if its chart is unchanged
redeploy name:
    #!/usr/bin/env bash
    set -euo pipefail
    # `flux reconcile` has no -A, and most (not all) HelmReleases live in flux-system.
    ns=$(kubectl get helmrelease -A -o "jsonpath={.items[?(@.metadata.name=='{{ name }}')].metadata.namespace}")
    [ -n "$ns" ] || { echo "no HelmRelease named '{{ name }}' (see: just fx hr)" >&2; exit 1; }
    flux reconcile helmrelease {{ name }} -n "$ns" --force

# Force-reconcile a Kustomization, or all of them
reconcile name='':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{ name }}" ]; then
      flux reconcile kustomization {{ name }} --with-source
    else
      flux get kustomizations -A --no-header | awk 'NF {print $1, $2}' | while read -r ns ks; do
        flux reconcile kustomization "$ks" -n "$ns" --with-source
      done
    fi

# Tail a controller's logs
logs controller='kustomize-controller':
    flux logs --follow --controller={{ controller }}
