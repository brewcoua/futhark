# Playbooks that build and configure the machines
mod ans '.just/ansible.just'
# Operator workstation setup and day-to-day chores
mod ops '.just/operator.just'
# OpenTofu plan/apply for the cloud-side modules
mod tf '.just/tofu.just'
# Cluster inspection — nodes, pods, logs, events
mod ks '.just/ks.just'
# Flux sync state and reconciliation
mod fx '.just/flux.just'
# K8up backups, restores and snapshots
mod bak '.just/backup.just'
# The mdBook under docs/
mod docs '.just/docs.just'

default: help

# List every recipe, module by module
help:
    @just --list --list-submodules
