# Ansible lookup plugin: resolve Proton Pass `pass://` references at runtime.
#
#   password: "{{ lookup('protonpass', 'pass://Futhark/infisical-ops/client-secret') }}"
#
# It shells out to the Proton Pass CLI (`pass-cli inject`, piping the reference on
# stdin) so the secret is resolved in-memory on the CONTROLLER and never written to
# disk. Requires an authenticated Proton Pass session on the operator machine
# (`pass-cli login`), or PAT auth via PROTON_PASS_PERSONAL_ACCESS_TOKEN. Values are
# cached per process so repeated references don't re-hit the CLI.
from __future__ import annotations

DOCUMENTATION = """
name: protonpass
author: Futhark
short_description: Resolve a Proton Pass pass:// secret reference
description:
  - Resolves one or more C(pass://vault/item/field) references via the Proton Pass CLI.
options:
  _terms:
    description: One or more pass:// references.
    required: true
  binary:
    description: Path to the Proton Pass CLI binary.
    type: string
    default: pass-cli
"""

import subprocess

from ansible.errors import AnsibleError
from ansible.plugins.lookup import LookupBase

_CACHE: dict[str, str] = {}


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)
        binary = self.get_option("binary")
        results = []
        for term in terms:
            ref = str(term).strip()
            if not ref.startswith("pass://"):
                raise AnsibleError(
                    "protonpass: reference must start with pass:// (got %r)" % ref
                )
            if ref in _CACHE:
                results.append(_CACHE[ref])
                continue
            try:
                proc = subprocess.run(
                    [binary, "inject"],
                    input="{{ %s }}" % ref,
                    capture_output=True,
                    text=True,
                    check=True,
                )
            except FileNotFoundError:
                raise AnsibleError(
                    "protonpass: '%s' not found on PATH — install the Proton Pass CLI "
                    "and run `pass-cli login`." % binary
                )
            except subprocess.CalledProcessError as exc:
                raise AnsibleError(
                    "protonpass: failed to resolve %s: %s"
                    % (ref, (exc.stderr or "").strip())
                )
            value = proc.stdout.rstrip("\n")
            if not value:
                raise AnsibleError(
                    "protonpass: %s resolved to an empty value (wrong vault/item/field, "
                    "or not logged in?)" % ref
                )
            _CACHE[ref] = value
            results.append(value)
        return results
