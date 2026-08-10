# futhark

A GitOps-driven homelab. Two Fedora nodes joined over a NetBird mesh run one k3s cluster.
Everything inside that cluster is reconciled by Flux from this repository, and everything that
cannot live inside it is managed by OpenTofu.

The tree splits along three planes, and almost every question about the repository resolves to
"which plane owns this?":

| Plane   | Owns                                                                           | Tool     | Where                                         |
| ------- | ------------------------------------------------------------------------------ | -------- | --------------------------------------------- |
| Host    | The machines: users, SSH, firewall, mesh join, the k3s install itself          | Ansible  | [`ansible/`](ansible/index.md)                |
| Cluster | Everything reconcilable from git: controllers, apps, namespaces, policy        | Flux     | [`flux/`, `infra/`, `nodes/`](gitops/flux.md) |
| Cloud   | Provider APIs no Kustomization can express: DNS, OIDC clients, the mesh policy | OpenTofu | [`tofu/`](tofu/index.md)                      |

The table says who owns what. What it cannot say is how the three meet: each plane hands off to
the next exactly once, and nothing reaches back the other way. Green is this repository, the one
source of truth. Amber is a third party, the things this repository can call but never own.

```d2
direction: down

classes: {
  boundary: {
    style: {
      stroke-width: 3
      stroke: seagreen
      fill: honeydew
    }
  }
  external: {
    style: {
      stroke: goldenrod
      fill: cornsilk
    }
  }
}

operator: operator machine {
  ansible: Ansible
  tofu: OpenTofu
  pass: pass-cli -> Proton Pass { class: external }
}

hosts: the machines {
  kenaz
  ogma
}

cluster: k3s cluster {
  flux: Flux
  workloads: controllers + apps
  flux -> workloads: reconciles
}

git: this repository { class: boundary }

cloud: provider APIs {
  bunny: Bunny DNS { class: external }
  netbird: NetBird { class: external }
  pocketid: Pocket ID { class: external }
}

operator.ansible -> hosts: provisions
operator.ansible -> cluster.flux: bootstraps once
operator.tofu -> cloud: applies
operator.pass -> operator.ansible: crown jewels, never committed

git -> cluster.flux: the only writer after bootstrap
hosts -> cluster: run
cluster.workloads -> cloud.pocketid: OIDC at runtime
```

Where to go next:

- Setting up from nothing: [Cold bootstrap](operations/setup.md).
- Something is broken: [Troubleshooting](operations/troubleshooting.md).
- Adding to the tree: [Conventions](conventions/layout.md).
- Replacing a credential: [Credential rotation](operations/rotation.md).
- Looking for a command: [Recipe reference](operations/recipes.md).

## What runs where

`kenaz` runs the k3s server, so it is both controller and worker, and it is the only node with
public ingress. `ogma` is an agent, and Pocket ID is pinned to it with a `nodeSelector`. Both are on the mesh and are addressed by
their mesh DNS name, never by a stored address. See [Nodes](ansible/nodes.md).

The pieces, roughly in dependency order: the Infisical operator, which syncs runtime secrets into
Kubernetes Secrets; Pocket ID for OIDC; cert-manager for Let's Encrypt over DNS-01; two Traefiks,
one public and one mesh-only; and a VictoriaMetrics, VictoriaLogs and Grafana stack. Each is
described in [Cluster infrastructure](gitops/infra.md), and the order they must come up in is
[Startup ordering](conventions/ordering.md).

## Secrets, in one paragraph

No credential is ever committed in the clear, and neither is any identifying value, because this
repository is public. Values that identify but grant nothing, such as node addresses and the
domain, are committed SOPS-encrypted. Anything that could bootstrap or re-key the system lives in
Proton Pass and is never committed at all. The cluster holds no credential for it, so a cluster
compromise cannot reach the keys that rebuild it. Per-app runtime secrets live in Infisical and
reach pods through the Infisical operator. The full rule, and what to do when you need a new one,
is in [Secrets](conventions/secrets.md). Replacing one is
[Credential rotation](operations/rotation.md).
