# oidc

Registers OIDC clients in Pocket ID and writes the minted client secret straight into OpenBao.
It is the one module allowed to write to OpenBao — see the write exception in
[Rules for every module](index.md). It replaces the manual "register in the Pocket ID admin
UI, hand-paste the secret into OpenBao" runbook.

## What it manages

One `pocketid_client` + `vault_kv_secret_v2` pair per app, in `clients.tf`. Add a new pair
following the existing block's shape as each app adopts OIDC login.

Each app owns its own non-secret OIDC config — client ID, discovery URL, hostname — in its own
ConfigMap. This module only produces the one thing that cannot be committed: the client
secret.

```bash
task tf:init -- oidc
task tf:plan -- oidc
task tf:apply -- oidc
```

## Prerequisites

A **Pocket ID admin API key**, created at Settings → Admin → API Keys on `auth.$DOMAIN`, stored
in the Proton Pass item `secrets.env` points at.

A **namespace-scoped OpenBao token** bound to the `oidc-writer` policy — write-only on
`secret/data/*` plus list and read on `secret/metadata/*` in that namespace.
`ansible/roles/openbao/tasks/namespaces.yml` creates this policy in every namespace it
bootstraps. Mint one per target namespace with the root token:

```bash
bao token create -namespace=<namespace> -policy=oidc-writer -period=768h
```

Store it in the Proton Pass item `VAULT_TOKEN` in `secrets.env` points at. Not the root token
— this module only ever needs to write one app's client secret into one namespace.

There is no CA to fetch. OpenBao is served through `traefik-internal`'s Ingress with the same
publicly-trusted wildcard certificate every other internal app uses, not a self-signed
listener cert — see `infra/openbao/app/configmap.yaml`.

## Verifying

- The Pocket ID admin UI shows the new client under Applications.
- `bao kv get -namespace=<namespace> secret/<name>` confirms the secret landed. The
  `oidc-writer` token has read access for exactly this.
- The app's `ExternalSecret` syncs on its next poll interval:
  `kubectl get externalsecret -n <app>` shows `SecretSynced`.
