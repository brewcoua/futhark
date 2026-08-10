import '_common.just'

# List this module's recipes
help:
    @just --list ops

# Fully set up this machine as a futhark operator (packages + collections + hooks + tofu)
setup: deps collections hooks _tf-init pass-session mesh

# Check this machine has a Proton Pass session, and explain how to get one if not
[no-exit-message]
pass-session:
    #!/usr/bin/env bash
    pass-cli info > /dev/null 2>&1 && { echo "Proton Pass session OK"; exit 0; }
    echo "No Proton Pass session. Mint a personal access token in the Proton Pass"
    echo "web app, then:"
    echo
    echo "  PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_… pass-cli login"
    exit 1

# Check this machine is on the mesh, and explain how to join if not
[no-exit-message]
mesh:
    #!/usr/bin/env bash
    # Plain `status`, not `--json`: nothing in `deps` installs jq.
    command -v netbird > /dev/null || { echo "netbird is not installed — run: just ops deps"; exit 1; }
    # The daemon writes this drop-in unless NB_DISABLE_SSH_CONFIG is set, and it turns off
    # StrictHostKeyChecking, sends UserKnownHostsFile to /dev/null and re-enables password auth
    # for every mesh peer. ansible/roles/netbird does the same for the nodes; this machine is not
    # one of them, so it is checked rather than converged.
    if [ -e /etc/ssh/ssh_config.d/99-netbird.conf ]; then
        echo "warning: NetBird is managing your system SSH client config, which weakens it."
        echo "         Turn it off, then remove the file it left behind:"
        echo
        echo "  sudo netbird service reconfigure --service-env NB_DISABLE_SSH_CONFIG=true"
        echo "  sudo systemctl restart netbird"
        echo "  sudo rm /etc/ssh/ssh_config.d/99-netbird.conf"
        echo
    fi
    netbird status 2> /dev/null | grep -q "Management: Connected" && { echo "NetBird mesh OK"; exit 0; }
    echo "This machine is not on the mesh. Log in over SSO:"
    echo
    # Spelled out rather than read from ansible's mesh_interface: nothing requires the operator
    # machine's interface to match the nodes' — it is no cluster node and has no firewalld rule
    # keyed on it — so this is a second decision that happens to agree, not the same one.
    echo "  netbird up --interface-name netbird0"
    echo
    echo "Then add this peer to the 'admin' group in the NetBird dashboard — that group is"
    echo "what every access rule names, and tofu/netbird deliberately leaves it empty."
    echo "See docs/src/tofu/netbird.md."
    exit 1

# Install every dependency: the dnf packages and daemons, the uv tools, and the pinned binaries
# in mise.toml
deps: (_require 'dnf') (_require 'uv')
    # Neither netbird nor mise ships in a Fedora repo, so their own ones come first. The netbird
    # fields match the yum_repository in ansible/roles/netbird, so operator and node install from
    # one place — and both are unpinned for the same reason: upstream distro packages.
    printf '[netbird]\nname=NetBird\nbaseurl=https://pkgs.netbird.io/yum/\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://pkgs.netbird.io/yum/repodata/repomd.xml.key\nenabled=1\n' | sudo tee /etc/yum.repos.d/netbird.repo > /dev/null
    sudo dnf copr enable -y jdxcode/mise
    # gnupg2/pcsc-lite/pinentry are the smartcard path every `sops -d` takes.
    #
    # just is here for completeness only — it has to already be installed for this to run.
    sudo dnf install -y ansible-core yamllint gnupg2 pcsc-lite pinentry just netbird mise
    sudo systemctl enable --now pcscd.socket
    # The daemon holds the mesh connection; `netbird up` in `just ops mesh` talks to it.
    sudo systemctl enable --now netbird
    # A fresh clone's config is untrusted until said otherwise.
    mise trust
    mise install
    uv tool install --upgrade ansible-lint
    uv tool install --upgrade pre-commit
    # kubernetes.core's modules (flux_bootstrap) import `kubernetes` directly, not the kubectl
    # binary. It goes into /usr/bin/python3's site-packages, since that is the interpreter
    # ansible-core actually runs modules with, not a uv tool's isolated venv.
    sudo uv pip install --python /usr/bin/python3 kubernetes
    # kubernetes.core.helm's idempotency check shells out to this plugin if present. Through
    # `mise exec`, since the shims are not on PATH until the operator's next login.
    mise exec -- sh -c 'helm plugin list | grep -q ^diff || helm plugin install --verify=false https://github.com/databus23/helm-diff'

# Generate the SOPS cluster age keypair (run once, at cold bootstrap)
age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    dir=$(mktemp -d)
    out="$dir/cluster.agekey"
    age-keygen -o "$out" 2>/dev/null
    echo
    echo "Public recipient — put this in .sops.yaml under the config/sops/cluster.sops.yaml rule:"
    grep -o 'age1[a-z0-9]*' "$out" | head -1
    echo
    echo "Private key is at $out and is NOT in the repo. Store it in Proton Pass as the"
    echo "'age key' field of the 'sops' item in your Proton Pass vault, then shred it:"
    echo "  shred -u $out"
    echo "config/sops/ops.sops.yaml points at it; flux_bootstrap creates flux-system/sops-age."

# Edit an encrypted file, creating it from its .example if absent. With no argument, lists
# the files that still need creating.
[no-exit-message]
sops file='':
    #!/usr/bin/env bash
    set -euo pipefail
    f="{{ file }}"
    if [ -z "$f" ]; then
      echo "usage: just ops sops <path/to/thing.sops.yaml>"
      echo
      echo "Files still to create:"
      for e in $(find . -name '*.sops.*.example' -not -path './.git/*' | sort); do
        [ -f "${e%.example}" ] || echo "  ${e%.example}"
      done
      exit 2
    fi
    # Accept either name, so tab-completing the template does the right thing.
    f="${f%.example}"
    if [ -f "$f" ]; then
      # sops exits 200 when the edit changed nothing, which is a normal outcome here, not a
      # failure worth a red recipe.
      sops "$f" || { rc=$?; [ "$rc" = 200 ] || exit "$rc"; }
      exit 0
    fi
    [ -f "$f.example" ] || { echo "no $f, and no $f.example to seed it from"; exit 1; }
    cp "$f.example" "$f"
    # Fail closed at both steps. An aborted edit or a failed encrypt must never leave a
    # plaintext file sitting at a *.sops.* path — that is the one mistake this whole
    # convention exists to prevent.
    if ! "${EDITOR:-vi}" "$f"; then
      rm -f "$f"; echo "editor exited non-zero, removed $f"; exit 1
    fi
    if ! sops -e -i "$f"; then
      rm -f "$f"; echo "encryption failed, removed plaintext $f"; exit 1
    fi
    echo "created and encrypted $f"

# Editing .sops.yaml alone leaves every file sealed to the old recipient, and Flux then fails
# to decrypt with "cannot get sops data key".
# Re-seal every encrypted file to the recipients .sops.yaml names (run after a key rotation)
[no-exit-message]
rekey:
    #!/usr/bin/env bash
    set -euo pipefail
    # -not -name '.sops.yaml' so the rules file itself, which carries no sops metadata, is
    # not mistaken for one of the files it describes.
    for f in $(find . -name '*.sops.*' -not -name '*.example' -not -name '.sops.yaml' -not -path './.git/*' | sort); do
      sops updatekeys -y "$f"
    done
    git diff --stat -- '*.sops.*'

# Install the repo's pre-commit hooks
hooks:
    pre-commit install

# Create or update the GitHub labels Renovate applies to its PRs
[no-exit-message]
labels: (_require 'gh')
    #!/usr/bin/env bash
    # Renovate does not create labels it cannot find — it drops them silently, so an unlabelled
    # dependency PR means this recipe has not been run here. The names are read out of the
    # packageRules rather than repeated here, because a name that does not match them is a label
    # nothing ever applies. Colour and description are this recipe's own business and follow from
    # the prefix, so adding a label to renovate.json5 needs no edit on this side.
    mapfile -t labels < <(grep -oE '"(type|renovate)/[a-z-]+"' .github/renovate.json5 |
      tr -d '"' | sort -u)
    (( ${#labels[@]} )) || { echo "no labels found in .github/renovate.json5"; exit 1; }
    for label in "${labels[@]}"; do
      case "$label" in
        type/major) colour=f6412d ;;
        type/minor) colour=ff9800 ;;
        type/*) colour=ffea19 ;;
        renovate/*) colour=027fa0 ;;
      esac
      # type/patch -> "patch update", renovate/helm -> "helm dependency"
      [[ $label == type/* ]] && suffix=update || suffix=dependency
      # --force is create-or-update. Nothing is ever deleted, so a label added by hand survives.
      gh label create "$label" --color "$colour" --description "${label#*/} $suffix" --force
    done

# Install the Ansible collections futhark's roles depend on
[working-directory('ansible')]
collections:
    ansible-galaxy collection install -r requirements.yml

[private]
_require bin:
    @command -v {{ bin }} > /dev/null || { echo "{{ bin }} is required and not on PATH" >&2; exit 1; }

[private]
_tf-init:
    @just tf init
