mod ans '.just/ansible.just'
mod ops '.just/operator.just'
mod tf '.just/tofu.just'
mod ks '.just/ks.just'
mod fx '.just/flux.just'
mod bak '.just/velero.just'
mod docs '.just/docs.just'

default:
    @just --list
