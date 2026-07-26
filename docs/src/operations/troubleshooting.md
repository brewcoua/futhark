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

This is the one that took the cluster down and presented as an OpenBao seal fault three layers
away. Check it before believing a cross-node bug is node-local.

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

## OpenBao won't come up

`task bao:policy-sync` waits for the pod, and fails with the container's own last 30 log lines
if it never answers — read those first, rather than assuming the sync is stuck.

Almost always it is the KMIP seal refusing to configure. Two distinct failures:

- `ItemNotFound` on `GetAttributes` — wrong key id. It must be the KMIP object UID, not the
  OVH service key id.
- `Operation is not authorized` on `GetAttributes` — the credential is missing an IAM action.

Both are covered in [The OpenBao seal](setup.md#the-openbao-seal).

Note that `bao status` exiting 2 means sealed-but-reachable, which should not linger — the
KMIP seal auto-unseals on every start, so a pod that stays sealed is a seal configuration
problem, not something to unseal by hand.

## An `ExternalSecret` never syncs

```bash
kubectl get externalsecret -A
kubectl describe externalsecret -n <ns> <name>
```

Check in this order:

1. Is the right store referenced? A node app must use `bao-node-<hostname>`, not `bao-infra`.
   See [Cluster infrastructure](../gitops/infra.md#external-secrets-operator).
2. Does the OpenBao namespace exist? `task bao:policy-sync` creates one per `nodes/*.k0s/`
   directory, so a newly added node needs a re-run.
3. Does ESO have write access to `Secret`s in that namespace? That is opt-in per namespace via
   the `rbac-eso-writer` template — see [Secrets](../conventions/secrets.md#eso-rbac).
4. Does the path actually hold the key? `task bao:kv -- get -namespace=<ns> secret/<name>`.

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
`external-secrets-config`, because the webhook's API key is an `ExternalSecret`.

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
