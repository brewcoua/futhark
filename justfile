# The tool version pins, shared with .github/workflows/{validate,docs}.yml — see
# config/versions.env. Declared here rather than in .just/operator.just, its only consumer:
# submodules inherit the root's env file, so one declaration reaches every recipe.
set dotenv-path := 'config/versions.env'

mod ans '.just/ansible.just'
mod ops '.just/operator.just'
mod tf '.just/tofu.just'
mod ks '.just/ks.just'
mod fx '.just/flux.just'
mod bak '.just/velero.just'
mod docs '.just/docs.just'

default:
    @just --list
