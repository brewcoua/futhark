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

# Init one tofu module, or all of them (no secrets needed: provider download only)
init module='':
    #!/usr/bin/env bash
    set -euo pipefail
    for d in {{ if module == '' { '$(find tofu -mindepth 1 -maxdepth 1 -type d)' } else { 'tofu/' + module } }}; do
      (cd "$d" && tofu init -input=false)
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
    sops exec-env secrets.sops.env 'pass-cli run -- tofu plan'

# Apply a tofu module
apply module:
    #!/usr/bin/env bash
    set -euo pipefail
    root='{{ justfile_directory() }}'
    cd tofu/{{ module }}
    {{ refs }}
    sops exec-env secrets.sops.env 'pass-cli run -- tofu apply'

# Validate a tofu module
[working-directory('tofu')]
validate module:
    cd {{ module }} && tofu validate
