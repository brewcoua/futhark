# oidc

Registers OIDC clients in Pocket ID and writes the minted client secret straight into Infisical,
so the app's `InfisicalStaticSecret` picks it up without a hand-paste.

It is the one module allowed to write to a secret store. See the write exception in
[Rules for every module](index.md).

## What it manages

One `pocketid_client` plus two `infisical_secret` resources per app, in `clients.tf`. Add a new
group following the existing blocks' shape as each app adopts OIDC login.

Plus the two fleet-wide groups in `groups.tf`, `administrators` and `users`. Every client sets
`allowed_user_groups` to both, so who may log in anywhere is one list rather than one per app, and
an app that maps roles reads the same `groups` claim. Grafana is the case that does: it maps
`administrators` to Admin and `users` to Viewer, and refuses anyone in neither.

Group membership is not managed here. A Pocket ID user is created by enrolling a passkey, so the
account exists before Tofu could reference it. Assign people under Settings, Groups in the admin
UI.

`allowed_user_groups` rejects everyone outside those groups the moment a client picks it up, so on
the first apply create the groups, add yourself to them, and only then apply the clients:

```bash
just tf apply oidc -target=pocketid_group.administrators -target=pocketid_group.users
# add yourself to both groups in the Pocket ID admin UI, then
just tf apply oidc
```

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

An **Infisical machine identity** with write access scoped to the folders this module targets, and
nothing else. Today that is `/nodes/<hostname>/<app>` for a per-node app and `/infra/monitoring`
for Grafana. A client whose folder is outside that scope fails the apply on the
`infisical_secret` resource, not on the Pocket ID one, so the client exists and its secret is
nowhere. Widen the scope in the Infisical UI, then apply again. Deliberately not the read-only
identity the cluster
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

- The Pocket ID admin UI shows the new client under Applications, and the groups under Groups.
- The Infisical UI shows the secret at the client's folder in the `prod` environment.
- The app's `InfisicalStaticSecret` syncs on its next interval:
  `kubectl get infisicalstaticsecret -n <app>`.

Replacing either credential this module uses is
[Credential rotation](../operations/rotation.md#the-pocket-id-api-token).
