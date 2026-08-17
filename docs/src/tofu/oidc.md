# oidc

Registers OIDC clients in Pocket ID and writes the minted client secret straight into Infisical,
so the app's `InfisicalStaticSecret` picks it up without a hand-paste.

It is the one module allowed to write to a secret store. See the write exception in
[Rules for every module](index.md).

## What it manages

One `pocketid_client` plus two `infisical_secret` resources per app, in `clients.tf`. Add a new
group following the existing blocks' shape as each app adopts OIDC login. The one exception is
`forgejo`, whose consumer cannot read Infisical at all; see
[The one client with no Infisical pair](#the-one-client-with-no-infisical-pair).

One of those clients is not an app. `pocketid_client.sso` is the oauth2-proxy in `infra/auth`, a
single relying party standing in for every internal app that speaks no OIDC. Its secrets go to
`/infra/auth`, and it is the only client whose callback path is fixed by the software rather than
chosen: oauth2-proxy always uses `/oauth2/callback`. Adding an app behind the SSO middleware needs
no new client here. See
[Internal ingresses are unauthenticated by default](../conventions/domains.md#internal-ingresses-are-unauthenticated-by-default).

Plus the two fleet-wide groups in `groups.tf`, `administrators` and `users`. Every client sets
`allowed_user_groups` to both, so who may log in anywhere is one list rather than one per app, and
an app that maps roles reads the same `groups` claim. Two apps do. Grafana maps `administrators`
to Admin and `users` to Viewer, and refuses anyone in neither. Open WebUI does the same through
`OAUTH_ROLES_CLAIM: groups`, `OAUTH_ADMIN_ROLES` and `OAUTH_ALLOWED_ROLES`.

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

### The one client with no Infisical pair

`pocketid_client.forgejo` is registered here like every other, but has no `infisical_secret`
resources. Forgejo runs on `brokkr`, outside the cluster, and that node holds no credential for any
secret store, so writing the values into Infisical would put them somewhere the consumer cannot
read. They leave through `outputs.tf` instead and are filed into Proton Pass by hand, which is the
same shape [b2](b2.md#filing-k8ups-key) uses for K8up's Backblaze key.

```bash
just tf output oidc -raw forgejo_oidc_client_id
just tf output oidc -raw forgejo_oidc_client_secret
```

Two things about this client differ from the rest and both are easy to get wrong:

- **The callback path's middle segment is not fixed.** Forgejo builds it as
  `<root_url>/user/oauth2/<login source name>/callback`, and that name is
  `forge_bootstrap_oauth_name` in `ansible/roles/forge_bootstrap/defaults/main.yml`. Both spell
  `pocketid`; change one and every login fails at the redirect.
- **The host is `git.$DOMAIN`, not `git.$SUB_INTERNAL.$DOMAIN`.** This one is on the public edge
  deliberately. It is the forge holding a mirror of this repository, so it has to be reachable when
  the cluster is not, and a mesh-only name would fail in exactly that case.

`ansible/roles/forge_bootstrap` is what registers the client inside Forgejo, with
`forgejo admin auth add-oauth` on the first converge and `update-oauth` on every one after. That
second form is what makes a rotated secret reach the running instance. See
[The standalone Podman plane](../gitops/podman.md#authentication).

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
nothing else. Today that is `/nodes/<hostname>/<app>` for a per-node app, `/infra/monitoring` for
Grafana, and `/infra/auth` for oauth2-proxy. A client whose folder is outside that scope fails the apply on the
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
