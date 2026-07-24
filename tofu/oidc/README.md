# oidc

Registers OIDC clients in Pocket ID and writes the minted client secret straight into OpenBao —
the one module in `tofu/` allowed to write (see `tofu/README.md`'s write-exception). Replaces the
manual "register in the Pocket ID admin UI, hand-paste the secret into OpenBao" runbook.

## What it manages

One `pocketid_client` + `vault_kv_secret_v2` pair per app — see `clients.tf`. Add a new pair
following the existing block's shape as each app adopts OIDC login. Each app owns its own
non-secret OIDC config (client ID, discovery URL, hostname) in its own ConfigMap — this module
only produces the one thing that can't be committed: the client secret.

```bash
cd tofu/oidc
tofu init  # no secrets needed, provider download only
pass-cli run --env-file secrets.env -- tofu plan
pass-cli run --env-file secrets.env -- tofu apply
```

(`task tofu:plan -- oidc` / `task tofu:apply -- oidc` wrap this — see
`.taskfiles/tofu/Taskfile.yaml`.)

## Prerequisites

- A Pocket ID admin API key (Settings > Admin > API Keys at `https://auth.brewen.dev`), stored
  at Proton Pass `futharkd/pocketid/api key`.
- The OpenBao root token, already in Proton Pass at `futharkd/openbao/root token` (same value
  ansible's `protonpass` lookup plugin uses).
- OpenBao's self-signed CA cert (`/etc/openbao/tls/openbao.crt` on ogma), stored at Proton Pass
  `futharkd/openbao/ca certificate`. Materialize it locally once (or again if it's ever rotated —
  it's a 10-year cert, see `ansible/roles/openbao/tasks/prep.yml`):

  ```bash
  pass-cli inject -i openbao-ca.crt.tpl -o openbao-ca.crt -f
  ```

  `openbao-ca.crt` is gitignored — only the `.tpl` pointer is committed.

## Verifying

- Pocket ID admin UI shows the new client under Applications.
- `bao kv get -namespace=<namespace> secret/<name>` (root token) confirms the secret landed.
- The app's ExternalSecret syncs on its next poll interval — `kubectl get externalsecret -n
<app>` shows `SecretSynced`.
