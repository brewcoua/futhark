# Node apps

What lives under `nodes/`, how it differs from `ansible/nodes/`, and which secrets a node app may
read. The procedure for adding one is
[Adding a node app](../conventions/layout.md#adding-a-node-app).

`nodes/` holds one directory per node that runs its own tenant apps, named `<hostname>.k8s` to
match the `workflow` field in `ansible/nodes/<hostname>/host.yml`. Inside it, one subdirectory per
app: `ks.yaml`, the Flux `Kustomization` CR, plus `app/`, the manifests.

This is a different `nodes/` from `ansible/nodes/`. Ansible's copy is provisioning data, meaning
how to reach and bootstrap the host. This one is what runs once the host exists. See
[Nodes](../ansible/nodes.md).

A node's apps read their secrets from Infisical under `/nodes/<hostname>/`, through that node's
own operator tier in `infisical-node-<hostname>`, never the infra tier. That separation is
enforced by RBAC and an admission policy rather than by convention. See
[Cluster infrastructure](infra.md#infisical-operator).

Not every cluster node gets a directory here. `ogma` runs no tenant apps. It is the cluster's
entrypoint, so what it carries is cluster-wide infra rather than per-node workloads: both Traefiks
and Pocket ID, all under `infra/` and all pinned with a `nodeSelector`.

## `kenaz.k8s`

`kenaz` runs the k3s server, so it is both controller and worker, plus Flux and most of `infra/`.
The exceptions are the pieces pinned to `ogma`: both Traefiks and Pocket ID. It runs three apps,
each in `nodes/kenaz.k8s/<app>/{ks.yaml,app/}` and each reading `/nodes/kenaz/<app>`:

| App          | Host                           | Reads from Infisical                                                               |
| ------------ | ------------------------------ | ---------------------------------------------------------------------------------- |
| `actual`     | `actual.$SUB_INTERNAL.$DOMAIN` | `ACTUAL_OPENID_CLIENT_ID`, `ACTUAL_OPENID_CLIENT_SECRET`                           |
| `open-webui` | `chat.$SUB_INTERNAL.$DOMAIN`   | `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `WEBUI_SECRET_KEY`, `OLLAMA_API_CONFIGS` |
| `searxng`    | `search.$SUB_INTERNAL.$DOMAIN` | `SEARXNG_SECRET`                                                                   |

`actual` and `open-webui` are OIDC clients of Pocket ID, so `tofu/oidc` writes their client ID
and secret. `searxng` speaks no OIDC and is gated by the `auth-sso` middleware instead, so its
one key is seeded by hand. So are `open-webui`'s other two: `WEBUI_SECRET_KEY` signs its JWTs,
and `OLLAMA_API_CONFIGS` carries the Ollama Cloud API key, which is the app's only model backend.

`open-webui` reaches `searxng` for web search by Service rather than by its ingress host, which
is what `infra/policies/namespaces/searxng/netpol-allow-from-open-webui.yaml` opens. See
[Pod-to-pod across namespaces](../conventions/network-policy.md#pod-to-pod-across-namespaces).

New apps land the same way. The step-by-step is
[Adding a node app](../conventions/layout.md#adding-a-node-app).
