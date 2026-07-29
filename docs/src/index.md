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

The table says who owns what. What it cannot say is how the three meet: each plane hands off to
the next exactly once, and nothing reaches back the other way.

```d2
direction: down

operator: operator machine {
  ansible: Ansible
  tofu: OpenTofu
  pass: pass-cli -> Proton Pass
}

hosts: the machines {
  kenaz
  ogma
}

cluster: k0s cluster {
  flux: Flux
  workloads: controllers + apps
  flux -> workloads: reconciles
}

git: this repository { style.stroke-width: 3 }

cloud: provider APIs {
  bunny: Bunny DNS
  tailscale: Tailscale
  pocketid: Pocket ID
}

operator.ansible -> hosts: provisions, then k0sctl installs k0s
operator.ansible -> cluster.flux: bootstraps once
operator.tofu -> cloud: applies
operator.pass -> operator.ansible: crown jewels, never committed

git -> cluster.flux: the only writer after bootstrap
hosts -> cluster: run
cluster.workloads -> cloud.pocketid: OIDC at runtime
```

If you are setting a machine up from nothing, start at [Cold bootstrap](operations/setup.md).
If something is broken, start at [Troubleshooting](operations/troubleshooting.md). If you are
adding to the tree, the rules you have to follow are under
[Conventions](conventions/layout.md).

Everything an operator runs goes through `task`:

```bash
just --list
```

## What runs where

`kenaz` is the k0s controller+worker and the only node with public ingress. `ogma` is a
worker; Pocket ID is pinned to it with a `nodeSelector`. Both are on the mesh and are addressed
by their MagicDNS name, never by a stored address — see [Nodes](ansible/nodes.md).

The pieces, roughly in dependency order: the Infisical operator (which syncs runtime secrets
into Kubernetes `Secret`s), Pocket ID (OIDC), cert-manager (Let's Encrypt over DNS-01), two
Traefiks — one public, one mesh-only — and a
VictoriaMetrics/VictoriaLogs/Grafana stack. Each is described in
[Cluster infrastructure](gitops/infra.md), and the order they must come up in is
[Startup ordering](conventions/ordering.md).

## Secrets, in one paragraph

No credential is ever committed in the clear, and neither is any identifying value, because
this repository is public. Values that identify but grant nothing — node addresses, the tailnet
name — are committed SOPS-encrypted. Anything that could bootstrap or re-key the system lives in
Proton Pass and is never committed at all; the cluster holds no credential for it, so a cluster
compromise cannot reach the keys that rebuild it. Per-app runtime secrets live in Infisical and
reach pods through the Infisical operator. The full rule, and what to do when you need a new one,
is in [Secrets](conventions/secrets.md).
