# oidc

Registers OIDC clients in Pocket ID and writes the minted client secret straight into Infisical,
so the app's `InfisicalStaticSecret` picks it up without a hand-paste.

It is the one module allowed to write to a secret store. See the write exception in
[Rules for every module](index.md).

## What it manages

One `pocketid_client` plus two `infisical_secret` resources per app, in `clients.tf`. Add a new
group following the existing blocks' shape as each app adopts OIDC login.

Each app owns its static OIDC config, meaning the discovery URL and hostname, in its own
ConfigMap. This module produces the two values that cannot be committed alongside them:

- The client secret.
- The client ID. It is not secret, but Pocket ID generates it, so only the apply knows its value.
  The provider's optional `client_id` argument applies at create time only, so pinning it on an
  existing client has no effect.

Both are written to the app's Infisical folder, and the app's `InfisicalStaticSecret` syncs that
folder into a Secret the Deployment consumes with `envFrom`. An app whose ConfigMap hardcodes a
client ID that Pocket ID never issued fails every login with `The requested OAuth 2.0 Client does
not exist.`

```bash
just tf init oidc
just tf plan oidc
just tf apply oidc
```

## Prerequisites

A **Pocket ID admin API key**, created at Settings → Admin → API Keys on `auth.$DOMAIN`, stored
in Proton Pass and referenced from `tofu.oidc` in `config/sops/ops.sops.yaml` as
`POCKETID_API_TOKEN: pass://<vault>/pocketid/api token`.

An **Infisical machine identity** with write access scoped to the folder this module targets,
`/nodes/<hostname>/<app>`, and nothing else. Deliberately not the read-only identity the cluster
authenticates with: this one writes, that one reads, and neither should substitute for the other.
Store its Universal Auth credentials in Proton Pass as the `client id` and `client secret` fields
of `infisical-tofu-writer`, and reference them from `tofu.oidc` as
`INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` and `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`. The provider
reads both from the environment, where `pass-cli run` has already resolved them.

The project ID goes in `tofu.oidc` as `TF_VAR_infisical_project_id`. It identifies an
account rather than granting anything, which is why it sits there as a literal value rather than
as a `pass://` reference. See [Secrets](../conventions/secrets.md).

Note the host: the provider is pinned to `https://eu.infisical.com`. That is a separate data
region, not a mirror of `app.infisical.com`, and pointing at the wrong one authenticates against a
tenant with no such project.

## Verifying

- The Pocket ID admin UI shows the new client under Applications.
- The Infisical UI shows the secret at `/nodes/<hostname>/<app>` in the `prod` environment.
- The app's `InfisicalStaticSecret` syncs on its next interval:
  `kubectl get infisicalstaticsecret -n <app>`.

Replacing either credential this module uses is
[Credential rotation](../operations/rotation.md#the-pocket-id-api-token).
