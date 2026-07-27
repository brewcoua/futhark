# Troubleshooting

Start here:

```bash
task k0s:status    # nodes, unhealthy pods, Flux sync state
task fx:failing    # only what isn't Ready
```

Then narrow down:

```bash
task k0s:describe -- <ns>/<pod>    # events, usually says why it won't schedule or mount
task k0s:previous -- <ns>/<pod>    # a crashlooper's last words
task k0s:warnings                  # Warning events cluster-wide
task fx:logs                       # kustomize-controller, or -- helm-controller
```

The rest of this page is the failure shapes that have actually happened here, and what each
one really means.

## Half of everything times out, intermittently

Symptom: some DNS lookups resolve and some hang; anything that resolves at startup crashloops;
direct-to-pod-IP works. Cross-node pod-to-pod traffic is being dropped.

CoreDNS runs one pod per node and kube-proxy load-balances 50/50, so exactly the remote
endpoint is unreachable and the failure looks intermittent rather than total.

```bash
# from a pod, against a pod on the *other* node
ping -c2 <remote pod IP>
```

If that fails, the tailnet ACL is almost certainly missing the `ip-in-ip` rule the IPIP
overlay needs. Full explanation and the fix:
[Pod to mesh networking](../ansible/networking.md#tailnet-acl-prerequisite-ip-in-ip).

This is the one that took the cluster down and presented as a storage fault three layers away.
Check it before believing a cross-node bug is node-local.

## `no route to host` from a pod dialing a node

This is a source-address fault, not a routing one, despite what the message says. tailscaled
drops packets whose source is not the node's own tailnet IP, so pod-sourced packets die on
egress even when the route is correct.

Isolate it on the node:

```bash
ping -c2 -I <this node's mesh IP> <peer mesh IP>        # should succeed
ping -c2 -I <this node's pod-bridge IP> <peer mesh IP>  # fails without the SNAT rule
```

Then check the rules are actually installed, and at a priority that is not being shadowed:

```bash
ip rule
systemctl status futhark-mesh-routes
iptables -t nat -L POSTROUTING -n | grep tailscale0
```

See [Pod to mesh networking](../ansible/networking.md). If `ip rule` shows kube-router at a
priority below 10, the whole script is a silent no-op.

## `kubectl exec`, `logs` and `port-forward` are down cluster-wide

Same root cause as the two above. `konnectivity-agent` dials the controller's
`konnectivity-server` over the mesh, so it is the first thing to break when pod → mesh
networking is broken, and it takes the whole exec path with it.

## Flux can't decrypt a manifest

`kustomize-controller` reporting `failed to decrypt` or an unparseable manifest means the
`sops-age` Secret is missing, holds the wrong key, or the file was encrypted to a recipient the
cluster key is not among.

```bash
kubectl get secret sops-age -n flux-system
sops -d <the file>          # works for you via the GPG card, independently of the cluster key
```

If `sops -d` succeeds locally but Flux fails, the file was sealed without the cluster age
recipient — check it matches the `(infra|nodes|config)` rule in `.sops.yaml` and re-run
`sops updatekeys` on it. Files under `ansible/` and `tofu/` are _supposed_ to fail this way in
cluster context; they are deliberately not sealed to the cluster key.

## An `InfisicalStaticSecret` never syncs

```bash
kubectl get infisicalstaticsecret -A
kubectl describe infisicalstaticsecret -n <ns> <name>
kubectl logs -n infisical-<tier> deploy/... -f
```

Check in this order:

1. Is the namespace in the right tier's `scopedNamespaces`? If not, the operator has no RBAC
   there and will not act at all — this is the most common cause after adding an app, and it
   looks like nothing happening rather than an error.
2. Is `infisicalAuthRef` pointing at that same tier's namespace? A node app must reference
   `infisical-node-<hostname>`, not `infisical-infra`. The node operator cannot read the infra
   tier's `InfisicalAuth`.
3. Was the object rejected at admission? A `secretPath` outside the namespace's tier never gets
   created — `kubectl apply` fails loudly, so check your shell history rather than the cluster.
4. Does the path actually hold the secret? Check the Infisical UI at that folder and
   environment.

## A Bitwarden `ExternalSecret` never syncs

Check the store is usable from that namespace at all — `conditions` on the `bitwarden`
`ClusterSecretStore` starts empty by design, so the answer is usually "the namespace was never
added". See [Secrets](../conventions/secrets.md#bitwarden-secrets-manager).

Then check `bitwarden-sdk-server` is up and its certificate issued: ESO talks to it over HTTPS
and reports a connection error, not a Bitwarden error, when it is not.

## A Kustomization is stuck, and its dependency is fine

Check for a namespace that does not exist yet. Every overlay under `infra/configs/` sets
kustomize's top-level `namespace:` field, so the whole overlay fails to apply if the target
`Namespace` is missing. A new component that declares its own namespace has to be added to
`infra/configs-ks.yaml`'s `dependsOn`. See
[Startup ordering](../conventions/ordering.md).

## A HelmRelease is Ready but running the old thing

`flux reconcile` will not reinstall a release whose chart version has not changed. Force it:

```bash
task fx:redeploy -- <name>
```

## A certificate never issues

```bash
task k0s:certs
kubectl describe certificaterequest -n <ns> <name>
```

Issuance goes through Let's Encrypt DNS-01 against the Bunny zone, so it waits on DNS
propagation and can legitimately take minutes. If it never completes, check the
`cert-manager-config` Kustomization is Ready — the `ClusterIssuer` lives there, behind
`infisical-operator-config`, because the webhook's API key is an `InfisicalStaticSecret`.

## `tofu apply` fails with `test(s) failed (400)`

A tailnet policy test caught a regression. The apply aborted and the tailnet kept its previous
policy, which is the intended behaviour. Plan does not catch this — it never submits the
document. See [tailscale](../tofu/tailscale.md#tests).

## `tofu validate` fails in pre-commit on a module you didn't touch

The module was never initialized locally. The hook deliberately does not run `init`:

```bash
task tf:init
```

See [Checks and CI](checks.md#pre-commit).
