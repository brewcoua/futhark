# bifrost

Generates the virtual keys the LLM gateway issues its clients, and writes each one into every
Infisical folder that reads it.

It is one of the two modules allowed to write to a secret store. See the write exception in
[Rules for every module](index.md).

## What it manages

Two `random_password` resources and three `infisical_secret` resources, in `keys.tf`. Nothing
else, and nothing outside Infisical.

| Secret            | Folder                    | Read by                                                      |
| ----------------- | ------------------------- | ------------------------------------------------------------ |
| `VK_OPEN_WEBUI`   | `/nodes/kenaz/bifrost`    | Bifrost, to know the token                                   |
| `OPENAI_API_KEYS` | `/nodes/kenaz/open-webui` | Open WebUI, to send it. Same value as `VK_OPEN_WEBUI`        |
| `VK_CLI`          | `/nodes/kenaz/bifrost`    | Bifrost. The operator's copy comes from this module's output |

That second row is why the module exists. A virtual key is only useful when both ends spell it
identically, and the two ends read different Infisical folders. Typed by hand, the two copies
agree until the first rotation.

## What it does not manage

It never calls Bifrost. A virtual key's token is whatever
`nodes/kenaz.k8s/bifrost/app/configmap.yaml` says it is, through an `env.` reference resolved at
startup, so there is no API to create it against. What the key may reach, meaning which providers
and which models, is `governance.virtual_keys[].provider_configs` in that same ConfigMap, in git,
next to the providers it names.

A third-party provider, `AirHelp-OSP/bifrost`, does create virtual keys over Bifrost's management
API. It is not used here. It would move the scope out of git and into the config store, where
`source_of_truth: "config.json"` would then have to stop managing that section, and it would make
an apply depend on Bifrost already running and reachable at a mesh-only hostname.

## Prerequisites

- The `tofu-writer` machine identity, as [`oidc`](oidc.md) uses. Its credentials and
  `TF_VAR_infisical_project_id` are the `tofu.bifrost` section of `config/sops/ops.sops.yaml`.
- `/nodes/kenaz/bifrost` exists in the `prod` environment, holding its four hand-seeded keys. See
  the folder table in [Cold bootstrap](../operations/setup.md#2-infisical).

## Applying

```bash
just tf apply bifrost
```

Verify: the three secrets appear in Infisical, `VK_OPEN_WEBUI` and `OPENAI_API_KEYS` hold the same
value, and both begin `sk-bf-`.

The prefix is not cosmetic. A virtual key without it is accepted on the `x-bf-vk` header only, and
every client here sends `Authorization` or `x-api-key` instead.

The Infisical operator resyncs each folder within a minute, and Bifrost reads its key at startup,
so restart it after the first apply:

```bash
kubectl -n bifrost rollout restart deployment/bifrost
```

## Reading the CLI key

`VK_CLI` has no cluster consumer. It is typed into a shell on the operator's machine, so the
module exposes it as an output rather than only writing it:

```bash
just tf output bifrost -raw vk_cli
```

## Rotating a key

Replace one resource and apply. Both writes follow, because the Infisical secrets read the
generated value rather than holding their own copy:

```bash
just tf apply bifrost -replace=random_password.vk_open_webui
kubectl -n bifrost rollout restart deployment/bifrost
kubectl -n open-webui rollout restart deployment/open-webui
```

The gap between the two restarts is a window where Open WebUI sends a key Bifrost no longer
accepts and every model request returns 401. Restart Bifrost first, and expect the window to last
until the Infisical operator's next sync rather than only the rollout.

Rotating `random_password.vk_cli` needs no restart of anything but Bifrost, and the new value is
read with `just tf output` above.

See [Credential rotation](../operations/rotation.md) for the rest of the repository's credentials.
