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

## Why the pod is scaled down first

`auth-dir` is a single-writer volume on a `ReadWriteOnce` PVC, and the running pod holds it. The
login pod mounts the same claim, so the Deployment has to let go of it first. Scaling to 0 also
takes `bifrost`'s `cli-proxy` provider offline for the duration; requests to `ollama` are
unaffected.

## Procedure

1. Release the volume.

   ```bash
   just ks kctl -n cli-proxy-api scale deployment/cli-proxy-api --replicas=0
   just ks kctl -n cli-proxy-api rollout status deployment/cli-proxy-api --timeout=60s
   ```

   Verify: `just ks pods cli-proxy-api` reports no resources.

2. Start a login pod on the same volume. Replace `--claude-login` with `--codex-login` or
   `--antigravity-login` for those providers; each opens its callback on a different port, so
   change the port in step 3 to match. The pod runs as root because the auth directory sits under
   `/root`, and it is deleted at the end of this procedure.

   ```bash
   just ks kctl -n cli-proxy-api run cli-proxy-login \
     --image=docker.io/eceasy/cli-proxy-api:v7.2.132 \
     --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"cli-proxy-login","image":"docker.io/eceasy/cli-proxy-api:v7.2.132","args":["/CLIProxyAPI/CLIProxyAPI","--claude-login"],"stdin":true,"tty":true,"volumeMounts":[{"name":"auth","mountPath":"/root/.cli-proxy-api"}]}],"volumes":[{"name":"auth","persistentVolumeClaim":{"claimName":"cli-proxy-api-auth"}}]}}'
   ```

   Verify: `just ks pods cli-proxy-api` shows `cli-proxy-login` Running.

3. Forward the callback port and complete the flow.

   ```bash
   just ks kctl -n cli-proxy-api port-forward pod/cli-proxy-login 54545:54545
   ```

   In a second terminal, read the authorization URL the pod printed and open it. This recipe
   follows the log, so leave it running to watch the rest of the flow:

   ```bash
   just ks logs cli-proxy-api cli-proxy-login
   ```

   Sign in. The vendor redirects to `http://localhost:54545/...`, the forward carries it to the
   pod, and the pod writes the token.

   Verify: the log reports the login succeeded, and

   ```bash
   just ks kctl -n cli-proxy-api exec cli-proxy-login -- ls /root/.cli-proxy-api
   ```

   lists at least one file.

4. Remove the login pod and bring the app back.

   ```bash
   just ks kctl -n cli-proxy-api delete pod cli-proxy-login
   just ks kctl -n cli-proxy-api scale deployment/cli-proxy-api --replicas=1
   just ks kctl -n cli-proxy-api rollout status deployment/cli-proxy-api --timeout=120s
   ```

   Verify: `just ks pods cli-proxy-api` shows one pod, Running and ready.

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

Nothing is committed until the token file is written, so a failed attempt leaves no state to undo.
Delete the pod and start again from step 2:

```bash
just ks kctl -n cli-proxy-api delete pod cli-proxy-login --ignore-not-found
```

If the Deployment was left at 0 replicas, scale it back to 1. `bifrost` serves `ollama` either
way, so nothing else in the cluster is waiting on this.

## Recovery

The tokens are on `cli-proxy-api-auth`, which carries `k8up.io/backup: "true"` and is covered by
the `cli-proxy-api` entry in `infra/backup/config/schedules.yaml`. Restoring the PVC restores every
linked account. See [Backup and recovery](recovery.md).

A restore is worth trying before repeating this procedure, because some vendors invalidate the
previous token when a new login succeeds, and re-linking every account is the slower path.
