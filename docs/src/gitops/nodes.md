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
The exceptions are the pieces pinned to `ogma`: both Traefiks and Pocket ID. It runs nine apps,
each in `nodes/kenaz.k8s/<app>/{ks.yaml,app/}` and each reading `/nodes/kenaz/<app>`:

| App             | Host                             | Reads from Infisical                                                                                                                              |
| --------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `actual`        | `actual.$SUB_INTERNAL.$DOMAIN`   | `ACTUAL_OPENID_CLIENT_ID`, `ACTUAL_OPENID_CLIENT_SECRET`                                                                                          |
| `open-webui`    | `chat.$SUB_INTERNAL.$DOMAIN`     | `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `WEBUI_SECRET_KEY`, `OPENAI_API_KEYS`, `POSTGRES_PASSWORD`                                              |
| `linkwarden`    | `links.$SUB_INTERNAL.$DOMAIN`    | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `NEXTAUTH_SECRET`, `POSTGRES_PASSWORD`                                                                    |
| `searxng`       | `search.$SUB_INTERNAL.$DOMAIN`   | `SEARXNG_SECRET`                                                                                                                                  |
| `vane`          | `ask.$SUB_INTERNAL.$DOMAIN`      | `OPENAI_API_KEY`                                                                                                                                  |
| `kvasir`        | `research.$SUB_INTERNAL.$DOMAIN` | `OPENAI_API_KEY`                                                                                                                                  |
| `bifrost`       | `llm.$SUB_INTERNAL.$DOMAIN`      | `BIFROST_ENCRYPTION_KEY`, `BIFROST_ADMIN_USERNAME`, `BIFROST_ADMIN_PASSWORD`, `OLLAMA_API_KEY`, `VK_OPEN_WEBUI`, `VK_CLI`, `VK_VANE`, `VK_KVASIR` |
| `cli-proxy-api` | none                             | nothing                                                                                                                                           |
| `munin`         | none                             | nothing                                                                                                                                           |

`actual`, `open-webui` and `linkwarden` are OIDC clients of Pocket ID, so `tofu/oidc` writes their
client ID and secret. `searxng`, `vane` and `kvasir` speak no OIDC and are gated by the
`auth-sso` middleware instead, though `kvasir` exposes only a runs page that way; the work reaches
it by Service, from the one namespace its network policy admits. Every remaining key is either
seeded by hand or minted by `tofu/bifrost`: `WEBUI_SECRET_KEY` signs Open WebUI's JWTs and `NEXTAUTH_SECRET`
signs Linkwarden's, both by hand, while `OPENAI_API_KEYS` and the two `OPENAI_API_KEY` entries are
the virtual keys `bifrost` issues its three in-cluster clients. See [bifrost](../tofu/bifrost.md).

`linkwarden` and `open-webui` keep their data outside their own namespace, in the shared
PostgreSQL under `infra/postgres`. What is left on each PVC is files rather than a database:
Linkwarden's page archives, and Open WebUI's uploads, vector store and model cache. `actual` is
the one that cannot follow them, because Actual Budget supports no backend but SQLite.
See [The shared database](infra.md#the-shared-database).

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
is one of the two apps here with no `Ingress`, no host, and no Infisical path: its whole
configuration is non-secret and ships in git, and the credentials it does hold are OAuth tokens on
a PVC, seeded by the browser flow in [CLI proxy login](../operations/cli-proxy-login.md).
`bifrost` registers it as
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

`munin` is the third provider, and the other app with no `Ingress`, no host and no Infisical path.
It is an Ollama serving one embedding model, `embeddinggemma:300m`, on CPU, registered as an
OpenAI-shaped custom provider with the same literal `unauthenticated` key and the same
`allow_private_network`. It exists because `kvasir` embeds every source it collects, both providers
above serve chat and nothing else, and Ollama Cloud publishes no embedding model. Its PVC holds
the weights and carries no `k8up.io/backup` annotation: the init container refetches them, so
there is nothing there worth a nightly snapshot. `vk-kvasir` is the only virtual key that names it.

### The search surface

`vane` answers questions from the web, and sits on two backends: `bifrost` for the model and
`searxng` for the results. It returns one cited answer in seconds.

It pins no model. It exposes a picker, and pinning one by environment variable would remove it, so
the choice is made per question: `ollama/deepseek-v4-flash:cloud` for most of them, and
`ollama/deepseek-v4-pro:cloud` when the reasoning matters more than the latency. Bifrost resolves
the `provider/model` prefix, so that is how the names are spelled in the app.

Its virtual key names the `ollama` provider only. The app has no use for `cli-proxy`, and a key
that cannot reach it cannot spend the subscription quota behind it on a search loop that does not
stop.

Its configuration is not held in git. `vane` reads its environment only on the boot that creates
`data/config.json` and owns that file afterwards, so its models, its embedding model and any later
key change are set in its Settings page and live on the PVC. That is also why
`nodes/kenaz.k8s/searxng/app/settings.yml` overrides the `wolframalpha` engine: `vane` routes
factual questions through it, and upstream ships it disabled.

`vane` has no login at all, so `auth-sso` is the only thing in front of it.

`kvasir` sits on the same two backends and answers the opposite kind of question. Where `vane`
returns one cited answer in seconds, `kvasir` runs [STORM](https://github.com/stanford-oval/storm)
against a topic for minutes to tens of minutes and returns a cited article. It is our own service,
built in [brewcoua/kvasir](https://github.com/brewcoua/kvasir), because upstream ships a library and
a demo but no server and no image.

Its `Ingress` serves one page and nothing that costs anything: what is running, which stage it is
in, and what each run has spent. The work does not arrive that way. The Open WebUI pipe function
calls it by Service, because that host sits behind `auth-sso` and a pod carries no session cookie,
so `infra/policies/namespaces/kvasir/netpol-allow-from-open-webui.yaml` is still what admits the
research itself.

`/healthz` and `/readyz` are the exception to that login, carved out by a second `Ingress` on the
same host in `app/ingress.yaml`. Traefik applies its middleware annotation to every router an
`Ingress` creates, so exempting two paths means a second object rather than a second path. That is
what gives it a Gatus check asserting a body, where every other app behind `auth-sso` can only
assert the redirect.

Its models are pinned rather than picked, one fast and one strong, and its virtual key names
`ollama` and `munin` and no more. That scoping matters more here than for `vane`: a run is
unattended and spends minutes issuing calls, so a key that cannot reach `cli-proxy` cannot drain
the subscription quota behind it when one goes wrong.

Every source it collects is embedded, to rank passages against each section, which is why it needs
`munin` and why a broken embeddings provider fails a run in article generation rather than at
startup.

It keeps nothing. Both writable paths are `emptyDir`, so it has no PVC and no backup Schedule. The
one thing it would keep is a Co-STORM session, and Co-STORM is deliberately not wired. Nothing
blocks it any more, now that `munin` serves the embeddings it needs; what it costs is a PVC and an
entry in `infra/backup/config/schedules.yaml`, and a round table nobody is holding is not worth a
nightly snapshot. The pipe function exposes both models regardless, so a Co-STORM session started
here survives only until the pod restarts.

The Open WebUI half is one Pipe function, installed by hand and living in Open WebUI's database
rather than in git. See [Cold bootstrap](../operations/setup.md#12-aftercare).

`open-webui` reaches `searxng` for web search, `bifrost` for models and `kvasir` for research,
`vane` and `kvasir` each reach `searxng` and `bifrost`, and `bifrost` reaches `cli-proxy-api` and
`munin`. None of them go through an ingress host, so nine files open those holes. See
[Pod-to-pod across namespaces](../conventions/network-policy.md#pod-to-pod-across-namespaces).

New apps land the same way. The step-by-step is
[Adding a node app](../conventions/layout.md#adding-a-node-app).
