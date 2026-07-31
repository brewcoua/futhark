import '_common.just'

# The $*_VERSION pins below come from config/versions.env, loaded by the root justfile and
# inherited by every submodule. Referenced as `$FOO` rather than `{{ FOO }}`: dotenv entries
# land in the environment, not in just's variable scope.

# Fully set up this machine as a futhark operator (packages + collections + hooks + tofu)
setup: deps collections hooks _tf-init pass-session

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

# Install required packages (ansible-core, ansible-lint, yamllint, sops, age, pass-cli,
# pre-commit, kubectl, helm, kustomize, k0sctl, flux, velero, rclone, tofu, mdbook, d2)
deps: (_require 'dnf') (_require 'uv')
    # opentofu (dnf) provides /usr/bin/tofu — the upstream install-opentofu.sh's rpm method
    # ships a same-path conflicting package literally named `tofu`, don't use it here.
    #
    # gnupg2/pcsc-lite/pinentry are the smartcard path every `sops -d` takes; age only ever
    # generates and holds the *cluster* recipient. See docs/src/conventions/secrets.md.
    #
    # just is here for completeness only — it has to already be installed for this to run.
    # bsdtar is what _fetch unpacks every release archive with, tarball or zip alike.
    sudo dnf install -y ansible-core yamllint kubernetes-client helm opentofu age gnupg2 pcsc-lite pinentry just bsdtar
    sudo systemctl enable --now pcscd.socket
    # kubernetes.core.helm's idempotency check shells out to this plugin if present.
    helm plugin list | grep -q ^diff || helm plugin install --verify=false https://github.com/databus23/helm-diff
    uv tool install --upgrade ansible-lint
    uv tool install --upgrade pre-commit
    # kubernetes.core's modules (flux_bootstrap) import `kubernetes` directly, not the kubectl
    # binary above. It goes into /usr/bin/python3's site-packages, since that is the interpreter
    # ansible-core actually runs modules with, not a uv tool's isolated venv.
    sudo uv pip install --python /usr/bin/python3 kubernetes
    # Pinned release binaries, one _fetch per tool. sops decrypts everything committed here;
    # pass-cli resolves the crown-jewel secrets that are deliberately not committed at all, in
    # either order depending on the plane — see docs/src/conventions/secrets.md.
    @just ops _fetch sops "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.linux.amd64"
    @just ops _fetch pass-cli "https://github.com/protonpass/pass-cli/releases/download/$PASS_CLI_VERSION/pass-cli-linux-x86_64"
    # Pinned release binary, not curl-to-sudo-bash of the installer script tracking master.
    @just ops _fetch kustomize "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" kustomize
    @just ops _fetch k0sctl "https://github.com/k0sproject/k0sctl/releases/download/$K0SCTL_VERSION/k0sctl-linux-amd64"
    # Every fx recipe and `just ks status` (via flux get) needs this; nothing else here
    # installed it. Upstream publishes no plain release binary worth pinning by hand.
    command -v flux > /dev/null || curl -fsSL https://fluxcd.io/install.sh | sudo bash
    # Every bak recipe shells out to this. Not needed on the cluster — the server side is the
    # HelmRelease in infra/backup — only on the operator machine driving a restore.
    @just ops _fetch velero "https://github.com/velero-io/velero/releases/download/$VELERO_VERSION/velero-$VELERO_VERSION-linux-amd64.tar.gz" "velero-$VELERO_VERSION-linux-amd64/velero"
    # Bootstrap only, and no recipe shells out to it: RCLONE_CONFIG is assembled by hand, and
    # `rclone config`/`obscure` are the only way to mint a Drive OAuth token and encode a crypt
    # password. See docs/src/operations/setup.md.
    @just ops _fetch rclone "https://github.com/rclone/rclone/releases/download/$RCLONE_VERSION/rclone-$RCLONE_VERSION-linux-amd64.zip" "rclone-$RCLONE_VERSION-linux-amd64/rclone"
    # Same pin .github/workflows/docs.yml reads, so a local `just docs build` renders what CI
    # publishes. The docs draw their graphs from ```d2 fences: mdbook-d2 is the preprocessor
    # mdbook invokes, and it shells out to the `d2` binary, so both have to be present or
    # `mdbook build` leaves every diagram as a code block. Release binaries, so no Rust toolchain.
    @just ops _fetch mdbook "https://github.com/rust-lang/mdBook/releases/download/$MDBOOK_VERSION/mdbook-$MDBOOK_VERSION-x86_64-unknown-linux-gnu.tar.gz" mdbook
    @just ops _fetch d2 "https://github.com/terrastruct/d2/releases/download/$D2_VERSION/d2-$D2_VERSION-linux-amd64.tar.gz" "d2-$D2_VERSION/bin/d2"
    @just ops _fetch mdbook-d2 "https://github.com/danieleades/mdbook-d2/releases/download/$MDBOOK_D2_VERSION/mdbook-d2-x86_64-unknown-linux-gnu.tar.gz" mdbook-d2

# Install one pinned release binary into /usr/local/bin, if it isn't on PATH already.
# `inner` is the binary's path inside the archive; omit it when the URL is the binary itself.
[private]
_fetch bin url inner='':
    #!/usr/bin/env bash
    set -euo pipefail
    command -v {{ bin }} > /dev/null && exit 0
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    if [ -z "{{ inner }}" ]; then
      curl -fsSL -o "$dir/{{ bin }}" "{{ url }}"
      src="$dir/{{ bin }}"
    else
      # bsdtar, not tar: rclone publishes a .zip and no tarball, and libarchive reads both.
      curl -fsSL -o "$dir/archive" "{{ url }}"
      bsdtar -xf "$dir/archive" -C "$dir"
      src="$dir/{{ inner }}"
    fi
    sudo install -m 755 "$src" /usr/local/bin/{{ bin }}

# Generate the SOPS cluster age keypair (run once, at cold bootstrap)
age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    dir=$(mktemp -d)
    out="$dir/cluster.agekey"
    age-keygen -o "$out" 2>/dev/null
    echo
    echo "Public recipient — put this in .sops.yaml under the (infra|nodes|config) rule:"
    grep -o 'age1[a-z0-9]*' "$out" | head -1
    echo
    echo "Private key is at $out and is NOT in the repo. Store it in Proton Pass as the"
    echo "'age key' field of the 'sops' item in the futharkd vault, then shred it:"
    echo "  shred -u $out"
    echo "config/secrets.sops.yaml points at it; flux_bootstrap creates flux-system/sops-age."

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

# Install the repo's pre-commit hooks
hooks:
    pre-commit install

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
