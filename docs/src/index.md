# futhark

A GitOps-driven homelab. Two Fedora nodes joined over a Tailscale mesh run one k0s cluster;
everything inside that cluster is reconciled by Flux from this repository, and everything
that cannot live inside it is managed by OpenTofu.

The tree splits along three planes, and almost every question about the repo resolves to
"which plane owns this?":

| Plane   | Owns                                                                              | Tool             | Where                                         |
| ------- | --------------------------------------------------------------------------------- | ---------------- | --------------------------------------------- |
| Host    | The machines: users, SSH, firewall, mesh join, the k0s install itself             | Ansible + k0sctl | [`ansible/`](ansible/index.md)                |
| Cluster | Everything reconcilable from git: controllers, apps, namespaces, policy           | Flux             | [`flux/`, `infra/`, `nodes/`](gitops/flux.md) |
| Cloud   | Provider APIs no Kustomization can express: DNS, OIDC clients, the tailnet policy | OpenTofu         | [`tofu/`](tofu/index.md)                      |

If you are setting a machine up from nothing, start at [Cold bootstrap](operations/setup.md).
If something is broken, start at [Troubleshooting](operations/troubleshooting.md). If you are
adding to the tree, the rules you have to follow are under
[Conventions](conventions/layout.md).

Everything an operator runs goes through `task`:

```bash
task --list
```

## What runs where

`kenaz` is the k0s controller+worker and the only node with public ingress. `ogma` is a
worker; OpenBao and Pocket ID are pinned to it with a `nodeSelector`. Both are on the mesh
and are addressed by their MagicDNS name, never by a stored address — see
[Nodes](ansible/nodes.md).

The pieces, roughly in dependency order: OpenBao (secrets, sealed by an external KMIP
service), External Secrets Operator (which pulls from OpenBao into Kubernetes `Secret`s),
Pocket ID (OIDC), cert-manager (Let's Encrypt over DNS-01), two Traefiks — one public, one
mesh-only — and a VictoriaMetrics/VictoriaLogs/Grafana stack. Each is described in
[Cluster infrastructure](gitops/infra.md), and the order they must come up in is
[Startup ordering](conventions/ordering.md).

## Secrets, in one paragraph

No credential is ever committed. Bootstrap secrets are `pass://` pointers to a Proton Pass
vault, resolved at runtime; runtime secrets live in OpenBao and reach pods through External
Secrets Operator. The same rule covers identifying non-credentials — a public IP, the tailnet
name — because this repository is public. The full rule, and what to do when you need a new
one, is in [Secrets](conventions/secrets.md).
