import '_common.just'

# List this module's recipes
help:
    @just --list ans

# Variadic like `just tf apply`, so the playbook's own flags reach it. That is what makes
# playbooks/setup.yml's six tags usable: `just ans setup brokkr --tags podman` re-converges one
# node's container plane, and `just ans setup --skip-tags podman` provisions the fleet's base layers
# during a cold bootstrap, before the secrets that plane needs exist.

# Run the setup playbook, against one host or all of them
[working-directory('ansible')]
setup host='' *args: render-secrets
    ansible-playbook playbooks/setup.yml {{ if host == '' { '' } else { '-l ' + host } }} {{ args }}

# Run the k3s cluster + Flux bootstrap playbook
[working-directory('ansible')]
k8s: render-secrets
    ansible-playbook playbooks/k8s.yml

# k8s.yml already fetches the kubeconfig as part of the converge, so regenerating is that same
# fetch on its own rather than a second code path. The rewrite of 127.0.0.1 to the controller's
# mesh address lives in the k8s_cluster role and only there.

# Re-fetch ansible/.generated/kubeconfig from the k3s controller
[working-directory('ansible')]
kubeconfig: render-secrets
    ansible-playbook playbooks/k8s.yml --tags kubeconfig

# Both stores, composed, in this order and no other. sops yields a document that still holds
# `{{ pass:// }}` references — it treats each value as an opaque string, so the braces survive
# — and pass-cli inject then resolves them against the operator's Proton Pass session.
#
# The output must never be loaded un-injected: `{{ }}` is Jinja too, so Ansible would try to
# evaluate `pass://<vault>/flux/deploy key` as an expression. That is why nothing under
# group_vars/ or host_vars/ is encrypted and no vars plugin decrypts anything — the playbooks and
# inventory read the rendered files instead.
#
# --out-file rather than a shell redirect: it applies pass-cli's default 0600, where `>` would
# use the umask. ansible/.generated/ is gitignored.

# Resolve the crown jewels from Proton Pass into ansible/.generated/secrets.yml, and decrypt the
# node addresses and cluster values beside them. The `tofu` subtree of config/sops/ops.sops.yaml is
# deliberately not read: it is not this plane's to see. Only `ansible` holds a reference to
# resolve, so the other two skip pass-cli entirely.
#
# `--extract` yields the subtree's own keys at the top level, which is why secrets.yml lands as
# `admin:`/`secrets:` — the shape the playbooks' vars_files expect — and why nodes.yml lands as a
# bare hostname map that group_vars/all/nodes.yml puts back under a `nodes` key. brokkr.yml is the
# same shape, read by group_vars/all/brokkr.yml. cluster.yml is the same file Flux and tofu read,
# just flattened out of the Secret.
render-secrets:
    @pass-cli info > /dev/null 2>&1 || { echo "no Proton Pass session — run: just ops pass-session" >&2; exit 1; }
    mkdir -p ansible/.generated
    sops -d --extract '["ansible"]' config/sops/ops.sops.yaml | pass-cli inject -f -o ansible/.generated/secrets.yml
    sops -d --extract '["nodes"]' config/sops/ops.sops.yaml > ansible/.generated/nodes.yml
    sops -d --extract '["brokkr"]' config/sops/ops.sops.yaml > ansible/.generated/brokkr.yml
    sops -d --extract '["stringData"]' config/sops/cluster.sops.yaml > ansible/.generated/cluster.yml

# Ping all nodes
[working-directory('ansible')]
ping:
    ansible all -m ping

# Lint playbooks and roles
[working-directory('ansible')]
lint:
    ansible-lint
