import '_kube.just'

# List this module's recipes
help:
    @just --list sec

# Vulnerability counts per workload, worst first
reports:
    kubectl get vulnerabilityreports -A --sort-by=.report.summary.criticalCount \
      -o 'custom-columns=NAMESPACE:.metadata.namespace,WORKLOAD:.metadata.labels.trivy-operator\.resource\.name,CRITICAL:.report.summary.criticalCount,HIGH:.report.summary.highCount,SCANNED:.report.updateTimestamp'

# Every finding in one report, with the version that fixes it
show report namespace:
    kubectl -n {{ namespace }} get vulnerabilityreport {{ report }} -o json \
      | jq -r '.report.vulnerabilities[] | [.severity, .vulnerabilityID, .resource, .installedVersion, .fixedVersion] | @tsv' \
      | column -t -N SEVERITY,CVE,PACKAGE,INSTALLED,FIXED

# Workload hardening checks the config-audit scanner failed
config:
    kubectl get configauditreports -A \
      -o 'custom-columns=NAMESPACE:.metadata.namespace,RESOURCE:.metadata.labels.trivy-operator\.resource\.name,CRITICAL:.report.summary.criticalCount,HIGH:.report.summary.highCount'

# Roles and ClusterRoles granting more than the assessment expects
rbac:
    kubectl get rbacassessmentreports,clusterrbacassessmentreports -A \
      -o 'custom-columns=NAMESPACE:.metadata.namespace,ROLE:.metadata.labels.trivy-operator\.resource\.name,HIGH:.report.summary.highCount,MEDIUM:.report.summary.mediumCount'

# CIS and NSA control results for the cluster itself
compliance:
    kubectl get clustercompliancereports \
      -o 'custom-columns=SPEC:.metadata.name,FAIL:.status.summary.failCount,PASS:.status.summary.passCount,UPDATED:.status.updateTimestamp'

# Scan an image the way CI would, before committing the pin that introduces it
scan image:
    trivy image --severity HIGH,CRITICAL --ignore-unfixed \
      --ignorefile {{ justfile_directory() }}/.trivyignore {{ image }}

# Drop a namespace's reports so the operator rebuilds them now, rather than on its own interval
rescan ns:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl get namespace "{{ ns }}" > /dev/null
    # The operator watches its own reports and recreates a missing one immediately. Deleting the
    # workload's pods would do it too, at the cost of restarting the workload.
    kubectl -n "{{ ns }}" delete vulnerabilityreports,configauditreports --all
    echo
    echo "deleted. scan jobs run one at a time, so give it a minute:"
    echo "  kubectl -n trivy-system get jobs"
