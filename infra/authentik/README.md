# authentik

SSO, exposed on `traefik-edge` (`auth.DOMAIN`, public) rather than internal-only — any protected
app can then live on either Traefik instance and still redirect to the same login host.

No Terraform/OpenTofu: futhark has none, and config-as-code here is Authentik's own **blueprints**
(`app/blueprints/*.yaml`, mounted from the `authentik-blueprints` ConfigMap) instead — pure YAML,
Flux-reconciled, no external apply step or state file.

The Infisical project id is centralized in `infra/_components/infisical` (not a secret — same class
as `infra/_components/domain` — so it's a committed constant, not something bridged through
Proton Pass/ansible like the actual Infisical machine-identity credentials are).

## Protecting an app

Add the `authentik` Middleware to the app's Ingress/IngressRoute (cross-namespace refs are already
allowed on both Traefik instances):

```yaml
# Ingress
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik@kubernetescrd
# IngressRoute
spec:
  routes:
    - middlewares:
        - name: authentik
          namespace: authentik
```

## Onboarding a new app

1. In Infisical, add a `<APP>_CLIENT_ID` / `<APP>_CLIENT_SECRET` pair under
   `/infra/authentik/app-clients` (synced into the `authentik-app-secrets` Secret, `envFrom`'d into
   the authentik server/worker — this is what a blueprint's `!Env` reads).
2. Add a blueprint file under `app/blueprints/` for the app:
   - **Proxy-fronted app** (no OIDC support of its own): `authentik_providers_proxy.proxyprovider`
     (`mode: forward_single`) + `authentik_core.application` + a `authentik_policies.policybinding`
     to a group. Add the provider's id to the embedded outpost's provider list. The app itself needs
     nothing further — the Middleware above is the entire integration.
   - **Native-OIDC app**: `authentik_providers_oauth2.oauth2provider` with `client_id`/`client_secret`
     set via `!Env [<APP>_CLIENT_ID]` / `!Env [<APP>_CLIENT_SECRET]` + `authentik_core.application`.
     The app's own `InfisicalStaticSecret` should read the _same_ `/infra/authentik/app-clients`
     path, so both sides always agree on the client secret — no reading it back out of Authentik
     after the fact.
3. `kustomization.yaml`'s `configMapGenerator` picks up any new file under `blueprints/` automatically.
