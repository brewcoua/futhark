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

(`task tf:plan -- oidc` / `task tf:apply -- oidc` wrap this — see
`.taskfiles/tofu/Taskfile.yaml`.)

## Prerequisites

- A Pocket ID admin API key (Settings > Admin > API Keys at `https://auth.brewen.dev`), stored
  at Proton Pass `futharkd/pocketid/api key`.
- A namespace-scoped OpenBao token bound to the `oidc-writer` policy (write-only on
  `secret/data/*` and list/read on `secret/metadata/*` in that namespace — see
  `ansible/roles/openbao/tasks/namespaces.yml`, which creates this policy in every namespace
  it bootstraps). Mint one per target namespace with the root token:
  ```bash
  bao token create -namespace=<namespace> -policy=oidc-writer -period=768h
  ```
  and store it at Proton Pass `futharkd/openbao/oidc writer token (<namespace>)`, referenced by
  `VAULT_TOKEN` in `secrets.env`. Not the root token — this module only ever needs to write one
  app's client secret into one namespace.

No CA to fetch: `vault.INT_DOMAIN` is served through traefik-internal's Ingress with the same
publicly-trusted wildcard LE cert every other internal app uses, not a self-signed listener cert
— see `infra/openbao/app/configmap.yaml`.

## Verifying

- Pocket ID admin UI shows the new client under Applications.
- `bao kv get -namespace=<namespace> secret/<name>` (the `oidc-writer` token also has read)
  confirms the secret landed.
- The app's ExternalSecret syncs on its next poll interval — `kubectl get externalsecret -n
<app>` shows `SecretSynced`.
