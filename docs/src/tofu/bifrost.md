# bifrost

Generates the virtual keys the LLM gateway issues its clients, and writes each one into every
Infisical folder that reads it.

It is one of the two modules allowed to write to a secret store. See the write exception in
[Rules for every module](index.md).

## What it manages

Four `random_password` resources and seven `infisical_secret` resources, in `keys.tf`. Nothing
else, and nothing outside Infisical.

| Secret                            | Folder                             | Read by                                                      |
| --------------------------------- | ---------------------------------- | ------------------------------------------------------------ |
| `VK_OPEN_WEBUI`                   | `/nodes/kenaz/bifrost`             | Bifrost, to know the token                                   |
| `OPENAI_API_KEYS`                 | `/nodes/kenaz/open-webui`          | Open WebUI, to send it. Same value as `VK_OPEN_WEBUI`        |
| `VK_CLI`                          | `/nodes/kenaz/bifrost`             | Bifrost. The operator's copy comes from this module's output |
| `VK_VANE`                         | `/nodes/kenaz/bifrost`             | Bifrost                                                      |
| `OPENAI_API_KEY`                  | `/nodes/kenaz/vane`                | Vane, to send it. Same value as `VK_VANE`                    |
| `VK_LDR`                          | `/nodes/kenaz/bifrost`             | Bifrost                                                      |
| `LDR_LLM_OPENAI_ENDPOINT_API_KEY` | `/nodes/kenaz/local-deep-research` | Local Deep Research, to send it. Same value as `VK_LDR`      |

The paired rows are why the module exists. A virtual key is only useful when both ends spell it
identically, and the two ends read different Infisical folders. Typed by hand, the two copies
agree until the first rotation.

Each app gets its own key rather than sharing one, so any of them can be revoked without
disturbing the others. The name on the consumer side is the app's, not this repository's: Vane
reaches Bifrost through its generic OpenAI provider and so reads `OPENAI_API_KEY`, and Local Deep
Research spells the whole path to the setting it locks.

## What it does not manage

It never calls Bifrost. A virtual key's token is whatever
`nodes/kenaz.k8s/bifrost/app/config.json` says it is, through an `env.` reference resolved at
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

Verify: the seven secrets appear in Infisical, each pair in the table above holds one value, and
every one of them begins `sk-bf-`.

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

`random_password.vk_vane` and `random_password.vk_ldr` work the same way, with their own consumer
to restart second:

```bash
just tf apply bifrost -replace=random_password.vk_vane
kubectl -n bifrost rollout restart deployment/bifrost
kubectl -n vane rollout restart deployment/vane
```

Vane needs one extra step. It copies `OPENAI_API_KEY` into `data/config.json` on the boot that
creates that file and reads the environment no further, so a restart alone leaves it sending the
old key. Open its Settings page after the rollout and paste the new value into the OpenAI
provider's API key field.

Rotating `random_password.vk_cli` needs no restart of anything but Bifrost, and the new value is
read with `just tf output` above.

See [Credential rotation](../operations/rotation.md) for the rest of the repository's credentials.
