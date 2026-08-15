# CLI proxy login

Seed an OAuth credential into `cli-proxy-api` so `bifrost` can serve a subscription model, and
prove the model answers through the gateway.

This is the one credential in the cluster no apply can create. Every provider `cli-proxy-api`
fronts is a CLI subscription rather than an API key, and the only way to obtain a token is the
vendor's browser flow. The result is a file under `auth-dir`, on the PVC, refreshed in place while
the pod runs.

Run this once per provider account, and again after a restore that predates an account being
added.

## Prerequisites

- The generated kubeconfig at `ansible/.generated/kubeconfig`. Every command below goes through a
  `just` recipe, which exports `KUBECONFIG` itself, so nothing here depends on the shell's own
  cluster context. `just ks kctl` is a plain `kubectl` passthrough for the steps no recipe covers.
- A browser on this machine, signed in to the account being linked.
- `nodes/kenaz.k8s/cli-proxy-api` already reconciled:

  ```bash
  just fx get
  ```

  Verify: the `cli-proxy-api` Kustomization reads Ready.

## Why the Deployment is scaled down first

`auth-dir` is a single-writer volume on a `ReadWriteOnce` PVC, and the running pod holds it. The
login pod mounts the same claim, so the Deployment has to let go of it first. Scaling to 0 also
takes `bifrost`'s `cli-proxy` provider offline for the duration; requests to `ollama` are
unaffected.

That is the reason this is a recipe rather than a list of commands. A flow abandoned halfway still
has to put the replica back, so the cleanup runs from a trap on every exit path.

## Procedure

```bash
just ks cli-proxy-login claude
```

The provider argument is `claude`, `codex`, or `antigravity`, and defaults to `claude`. Each
vendor fixes its own OAuth callback port, so the recipe forwards the right one per provider.

The recipe scales the Deployment to 0, starts a login pod on the same volume with the app's
ConfigMap mounted, forwards the callback port, and follows the pod's log. It reads the image from
the Deployment, so the login always runs the build the server runs.

1. Wait for the authorization URL to appear in the log, then open it and sign in. The vendor
   redirects to `http://localhost:<port>/...`, the forward carries it to the pod, and the pod
   writes the token.

2. Press Ctrl-C once the log reports the login succeeded. The recipe deletes the login pod, scales
   the Deployment back to 1, and waits for the rollout.

Verify: one pod, Running and ready.

```bash
just ks pods cli-proxy-api
```

## Verify end to end

From a host on the mesh, ask the gateway what it can serve. Read `<virtual key>` with
`just tf output bifrost -raw vk_cli`. See [bifrost](../tofu/bifrost.md).

```bash
curl -sS https://llm.$SUB_INTERNAL.$DOMAIN/v1/models \
  -H "Authorization: Bearer <virtual key>" | jq -r '.data[].id'
```

Success is at least one `cli-proxy/` model in the list. If only `ollama/` models appear, the token
did not land: `cli-proxy-api` starts and answers `/healthz` with an empty `auth-dir`, so a healthy
pod is not evidence of a credential.

Then send one request through it:

```bash
curl -sS https://llm.$SUB_INTERNAL.$DOMAIN/anthropic/v1/messages \
  -H "x-api-key: <virtual key>" \
  -H "content-type: application/json" \
  -d '{"model":"cli-proxy/<model id>","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
```

Success is a `content` array in the response rather than an `error` object.

## If the login fails partway

Nothing is written until the token file is, so a failed attempt leaves no state to undo. Press
Ctrl-C and run the recipe again.

If the recipe was killed in a way that skipped its trap, `SIGKILL` rather than Ctrl-C, the login
pod may still exist and the Deployment may still be at 0. Undo both by hand:

```bash
just ks kctl -n cli-proxy-api delete pod cli-proxy-login --ignore-not-found
just ks kctl -n cli-proxy-api scale deployment/cli-proxy-api --replicas=1
```

`bifrost` serves `ollama` either way, so nothing else in the cluster is waiting on this.

## Recovery

The tokens are on `cli-proxy-api-auth`, which carries `k8up.io/backup: "true"` and is covered by
the `cli-proxy-api` entry in `infra/backup/config/schedules.yaml`. Restoring the PVC restores every
linked account. See [Backup and recovery](recovery.md).

A restore is worth trying before repeating this procedure, because some vendors invalidate the
previous token when a new login succeeds, and re-linking every account is the slower path.
