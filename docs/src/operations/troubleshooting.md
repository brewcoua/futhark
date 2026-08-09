# Troubleshooting

Failure shapes that have actually happened here, what each one really means, and how to confirm
it. Work top-down: the first three sections share one root cause and account for the worst outage
this cluster has had.

Start here:

```bash
just ks status     # nodes, unhealthy pods, Flux sync state
just fx failing    # only what isn't Ready
```

Then narrow down:

```bash
just ks describe <ns> <pod>    # events, usually says why it won't schedule or mount
just ks previous <ns> <pod>    # a crashlooper's last words
just ks warnings               # Warning events cluster-wide
just fx logs                   # kustomize-controller, or name another
```

## Half of everything times out, intermittently

Symptom: some DNS lookups resolve and some hang; anything that resolves at startup crashloops;
direct-to-pod-IP works. Cross-node pod-to-pod traffic is being dropped.

CoreDNS runs one pod per node and kube-proxy load-balances 50/50, so exactly the remote
endpoint is unreachable and the failure looks intermittent rather than total.

```bash
# from a pod, against a pod on the *other* node
ping -c2 <remote pod IP>
```

If that fails, the mesh policy is almost certainly not passing every protocol, which the IPIP
overlay needs. Full explanation and the fix:
[Pod to mesh networking](../ansible/networking.md#the-all-protocol-policy-rule).

This is the one that took the cluster down and presented as a storage fault three layers away.
Check it before believing a cross-node bug is node-local.

## `no route to host` from a pod dialing a node

This is a source-address fault, not a routing one, despite what the message says. The
WireGuard peer drops packets whose source is not the node's own mesh address, so pod-sourced
packets die on egress even when the route is correct.

Isolate it on the node:

```bash
ping -c2 -I <this node's mesh IP> <peer mesh IP>        # should succeed
ping -c2 -I <this node's pod-bridge IP> <peer mesh IP>  # fails without the SNAT rule
```

Then check the rules are actually installed, and at a priority that is not being shadowed:

```bash
ip rule
systemctl status futhark-mesh-routes
iptables -t nat -L POSTROUTING -n | grep netbird0
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
recipient. Check it against the `config/sops/cluster.sops.yaml` rule in `.sops.yaml` and re-run
`sops updatekeys` on it. `config/sops/ops.sops.yaml` is _supposed_ to fail this way in cluster
context; it is deliberately not sealed to the cluster key, and Flux is never given it.

## An `InfisicalStaticSecret` never syncs

```bash
kubectl get infisicalstaticsecret -A
kubectl describe infisicalstaticsecret -n <ns> <name>
kubectl logs -n infisical-<tier> deploy/... -f
```

Check in this order:

1. Is the namespace in the right tier's `scopedNamespaces`? If not, the operator has no RBAC
   there and will not act at all. This is the most common cause after adding an app, and it looks
   like nothing happening rather than an error.
2. Is `infisicalAuthRef` pointing at that same tier's namespace? A node app must reference
   `infisical-node-<hostname>`, not `infisical-infra`. The node operator cannot read the infra
   tier's `InfisicalAuth`.
3. Was the object rejected at admission? A `secretPath` outside the namespace's tier never gets
   created, and `kubectl apply` fails loudly, so check your shell history rather than the cluster.
4. Does the path actually hold the secret? Check the Infisical UI at that folder and
   environment.

## A Kustomization is stuck, and its dependency is fine

Check for a namespace that does not exist yet. Every overlay under `infra/policies/` sets
kustomize's top-level `namespace:` field, so the whole overlay fails to apply if the target
`Namespace` is missing, as does any chart that writes into a namespace it does not create,
which is how `infisical-operator` fails when `scopedNamespaces` names one. Add it to
`infra/namespaces/app/namespaces.yaml`; nothing else declares namespaces. See
[Startup ordering](../conventions/ordering.md).

## A HelmRelease is Ready but running the old thing

`flux reconcile` will not reinstall a release whose chart version has not changed. Force it:

```bash
just fx redeploy <name>
```

## A certificate never issues

```bash
just ks certs
kubectl describe certificaterequest -n <ns> <name>
```

Issuance goes through Let's Encrypt DNS-01 against the Bunny zone, so it waits on DNS
propagation and can legitimately take minutes. If it never completes, check the
`cert-manager-config` Kustomization is Ready. The `ClusterIssuer` lives there, behind
`infisical-operator-config`, because the webhook's API key is an `InfisicalStaticSecret`.

## `just tf apply netbird` returns 403 on `netbird_account_settings`

The `netbird-policy` service user is at Network Admin, which reads account settings and cannot
write them. Promote it to Admin for the apply, then demote it again:
[Applying account settings](../tofu/netbird.md#applying-account-settings).

## A `just tf plan` returns 401, or Ansible fails to mint a setup key

The credential expired or was revoked. Which token, and what each lapse breaks, is
[NetBird token expiry](checks.md#netbird-token-expiry). Replacements are in
[Credential rotation](rotation.md).

If instead a `pass://` reference comes through as a literal string, the Proton Pass session is
gone rather than the credential. `pass-cli info` says which.

## `tofu validate` fails in pre-commit on a module you didn't touch

The module was never initialized locally. The hook deliberately does not run `init`:

```bash
just tf init
```

See [Checks and CI](checks.md#pre-commit).
