import '_common.just'

# Resolves a module's refs.env, if it has one — see
# docs/src/tofu/index.md#values-another-plane-owns for the format and who owns what.
#
# `< "$f"` rather than a pipe on purpose: a pipeline would run the loop in a subshell and the
# exports would not survive it. Splitting by hand rather than `IFS='='`, because an extract
# expression may itself contain `=`.
#
# A raw string, so the shell's own `$` and `\` reach the recipe untouched; `$root` is set by
# each recipe before the splice, since the loop runs from inside the module's directory.
refs := '''
    f=refs.env
    if [ -f "$f" ]; then
      while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        var=${line%%=*}; ref=${line#*=}
        src=${ref%%#*}; key=${ref#*#}
        val=$(sops -d --extract "$key" "$root/$src") || {
          echo "refs.env: cannot read $key from $src" >&2; exit 1; }
        export "$var=$val"
      done < "$f"
    fi
'''

# The s3 backend's non-secret settings, for the one module that has one — tofu/b2, whose state
# cannot be local (backend.tf says why). Env vars rather than more `-backend-config` flags for two
# reasons: `endpoints` is a nested object, which that flag's KEY=VALUE form cannot express, and
# flag values are cached in .terraform while env vars are not, so plan and apply have to re-export
# them anyway. Spliced after `refs`, which is where TF_VAR_region comes from.
#
# A no-op for a module without a backend.tf, which is all the others.
backend_env := '''
    if [ -f backend.tf ]; then
      export AWS_REGION="$TF_VAR_region"
      export AWS_ENDPOINT_URL_S3="https://s3.$TF_VAR_region.backblazeb2.com"
    fi
'''

# Init one tofu module, or all of them (a module with a backend also needs both secret stores)
init module='':
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{ justfile_directory() }}'
    for d in {{ if module == '' { '$(find tofu -mindepth 1 -maxdepth 1 -type d)' } else { 'tofu/' + module } }}; do
      if [ ! -f "$d/backend.tf" ]; then
        (cd "$d" && tofu init -input=false)
        continue
      fi
      # Skipped rather than failed when the module's secrets do not exist yet: `just ops setup`
      # calls this recipe at step 3 of the cold bootstrap, and the encrypted files are not written
      # until step 5. Without this, a fresh operator machine cannot finish setup at all.
      if [ ! -f "$d/secrets.sops.env" ]; then
        echo "$d: has a backend but no secrets.sops.env yet — run \`just tf init $(basename "$d")\` once it exists" >&2
        continue
      fi
      # Same composition as plan/apply below, because initialising a remote backend authenticates
      # against it. This is why `just tf init` is no longer secret-free.
      (
        cd "$d"
        {{ refs }}
        {{ backend_env }}
        export TF_BACKEND_KEY="$(basename "$d")/terraform.tfstate"
        sops exec-env secrets.sops.env 'pass-cli run -- tofu init -input=false -backend-config="bucket=$TF_BACKEND_BUCKET" -backend-config="key=$TF_BACKEND_KEY"'
      )
    done

# Both stores, composed, in this order and no other. `sops exec-env` puts the module's whole
# secrets.sops.env into the environment — identifying values as themselves, credentials as
# bare `pass://` URIs — and `pass-cli run` then rewrites every variable whose value is such a
# URI into the real secret before exec'ing tofu. Neither ever writes a value to disk. Needs a
# Proton Pass session (`pass-cli info`) and the GPG card for sops.
#
# Braces are deliberately absent here, unlike config/secrets.sops.yaml: `run` resolves bare
# URIs and ignores braced ones, which is the exact inverse of `inject`. Getting it backwards
# fails by passing the literal string through to the provider, which reads as a bad credential.
#
# A third source, for values another plane already owns: refs.env above. A module's own
# secrets.sops.env holds only what nothing else has — everything shared is read from its one
# canonical home instead, because two encrypted copies of a value drift silently and nothing
# catches it. All of them seal to the same operator key, so this costs no extra card touch.

# Plan a tofu module
plan module:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{ justfile_directory() }}'
    cd tofu/{{ module }}
    {{ refs }}
    {{ backend_env }}
    sops exec-env secrets.sops.env 'pass-cli run -- tofu plan'

# Apply a tofu module
apply module:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{ justfile_directory() }}'
    cd tofu/{{ module }}
    {{ refs }}
    {{ backend_env }}
    sops exec-env secrets.sops.env 'pass-cli run -- tofu apply'

# Needed once when a module takes over something created by hand — see docs/src/tofu/b2.md — and
# never again on another machine, for a module whose state is remote.

# Adopt an already-existing provider resource into a module's state
adopt module address id:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{ justfile_directory() }}'
    cd tofu/{{ module }}
    {{ refs }}
    {{ backend_env }}
    sops exec-env secrets.sops.env 'pass-cli run -- tofu import {{ address }} {{ id }}'

# Validate a tofu module
[working-directory('tofu')]
validate module:
    cd {{ module }} && tofu validate
