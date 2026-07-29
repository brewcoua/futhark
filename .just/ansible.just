import '_common.just'

# Run the setup playbook, against one host or all of them
[working-directory('ansible')]
setup host='': render-secrets
    ansible-playbook playbooks/setup.yml {{ if host == '' { '' } else { '-l ' + host } }}

# Run the k0s cluster + Flux bootstrap playbook
[working-directory('ansible')]
k0s: render-secrets
    ansible-playbook playbooks/k0s.yml

# Both stores, composed, in this order and no other. sops yields a document that still holds
# `{{ pass:// }}` references — it treats each value as an opaque string, so the braces survive
# — and pass-cli inject then resolves them against the operator's Proton Pass session.
#
# The output must never be loaded un-injected: `{{ }}` is Jinja too, so Ansible would try to
# evaluate `pass://futharkd/flux/deploy key` as an expression. That is why the template lives
# in config/ rather than under group_vars/, where the community.sops vars plugin would pick it
# up automatically, and why the playbooks read the rendered file by an explicit vars_files.
#
# --out-file rather than a shell redirect: it applies pass-cli's default 0600, where `>` would
# use the umask. ansible/.generated/ is gitignored.

# Resolve the crown jewels from Proton Pass into ansible/.generated/secrets.yml
render-secrets:
    @pass-cli info > /dev/null 2>&1 || { echo "no Proton Pass session — run: just ops pass-session" >&2; exit 1; }
    mkdir -p ansible/.generated
    sops -d config/secrets.sops.yaml | pass-cli inject -f -o ansible/.generated/secrets.yml

# Ping all nodes
[working-directory('ansible')]
ping:
    ansible all -m ping

# Lint playbooks and roles
[working-directory('ansible')]
lint:
    ansible-lint
