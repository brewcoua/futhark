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
The exceptions are the pieces pinned to `ogma`: both Traefiks and Pocket ID. It runs five apps,
each in `nodes/kenaz.k8s/<app>/{ks.yaml,app/}` and each reading `/nodes/kenaz/<app>`:

| App             | Host                           | Reads from Infisical                                                                                                      |
| --------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `actual`        | `actual.$SUB_INTERNAL.$DOMAIN` | `ACTUAL_OPENID_CLIENT_ID`, `ACTUAL_OPENID_CLIENT_SECRET`                                                                  |
| `open-webui`    | `chat.$SUB_INTERNAL.$DOMAIN`   | `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `WEBUI_SECRET_KEY`, `OPENAI_API_KEYS`                                           |
| `searxng`       | `search.$SUB_INTERNAL.$DOMAIN` | `SEARXNG_SECRET`                                                                                                          |
| `bifrost`       | `llm.$SUB_INTERNAL.$DOMAIN`    | `BIFROST_ENCRYPTION_KEY`, `BIFROST_ADMIN_USERNAME`, `BIFROST_ADMIN_PASSWORD`, `OLLAMA_API_KEY`, `VK_OPEN_WEBUI`, `VK_CLI` |
| `cli-proxy-api` | none                           | nothing                                                                                                                   |

`actual` and `open-webui` are OIDC clients of Pocket ID, so `tofu/oidc` writes their client ID
and secret. `searxng` speaks no OIDC and is gated by the `auth-sso` middleware instead, so its
one key is seeded by hand. So is every key `bifrost` reads, and `open-webui`'s other two:
`WEBUI_SECRET_KEY` signs its JWTs, and `OPENAI_API_KEYS` is the virtual key `bifrost` issues it.

### The model gateway

`bifrost` is where every model request in the cluster goes. It holds the provider credentials, so
an app that wants a model needs a virtual key rather than a provider key, and adding a provider
changes one ConfigMap instead of every app that would have called it. `open-webui` reaches it by
Service, on its OpenAI-compatible surface, and `OLLAMA_API_CONFIGS` moved out of
`/nodes/kenaz/open-webui` when it stopped calling Ollama Cloud directly.

`client.allowed_origins` in its `config.json` lists one entry, its own ingress host. Bifrost defaults
that to `*`, which would let any page the operator has open drive the dashboard and management API from
the browser on the `governance.auth_config` session. Nothing else here looks at `Origin`: the netpols
match namespaces and the Traefik middleware counts requests. One entry is enough because no other caller
is a browser — `open-webui` and `gatus` call by Service and by health probe, CLI clients send no `Origin`,
and `glance` loads the favicon as an image, which CORS does not gate. The cost is that the dashboard no
longer answers a browser pointed at a `kubectl port-forward`.

`cli-proxy-api` is the second provider behind it, turning subscription CLI logins into an API. It
is the one app here with no `Ingress`, no host, and no Infisical path: its whole configuration is
non-secret and ships in git, and the credentials it does hold are OAuth tokens on a PVC, seeded by
the browser flow in [CLI proxy login](../operations/cli-proxy-login.md). `bifrost` registers it as
an Anthropic-shaped custom provider, so a Claude request keeps its wire format the whole way
rather than round-tripping through the OpenAI schema.

That provider's key in `config.json` is the literal `unauthenticated`, which is not a credential
and grants nothing. `cli-proxy-api` serves an empty `api-keys` list and ignores whatever arrives,
but `bifrost` drops a key with an empty value and then reports `no valid keys found for provider`
without ever calling it. `allow_private_network` on the same provider is the other half: `bifrost`
refuses RFC 1918 destinations by default, which is every Service in the cluster.

That provider's models are spelled out rather than left as `*`. A wildcard makes `bifrost` discover
the catalog at startup and rewrite anything its Anthropic model list does not recognise, so the
Gemini ids arrive scrambled and unusable. The list is the one thing here that goes stale: linking
another account in `cli-proxy-api` adds models that stay invisible until they are added to
`config.json` too.

`open-webui` reaches `searxng` for web search, and both `open-webui` and `bifrost` reach their
backends by Service rather than by an ingress host. Three files open those holes. See
[Pod-to-pod across namespaces](../conventions/network-policy.md#pod-to-pod-across-namespaces).

New apps land the same way. The step-by-step is
[Adding a node app](../conventions/layout.md#adding-a-node-app).
