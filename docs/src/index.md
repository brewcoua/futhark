# futhark

A GitOps-driven homelab. Three Fedora nodes joined over a NetBird mesh. Two of them run one k3s
cluster, reconciled by Flux from this repository; the third runs the git forge under Podman,
deliberately outside it. Everything that cannot live inside a cluster at all is managed by OpenTofu.

The tree splits along four planes, and almost every question about the repository resolves to
"which plane owns this?":

| Plane      | Owns                                                                           | Tool         | Where                                         |
| ---------- | ------------------------------------------------------------------------------ | ------------ | --------------------------------------------- |
| Host       | The machines: users, SSH, firewall, mesh join, the k3s install itself          | Ansible      | [`ansible/`](ansible/index.md)                |
| Cluster    | Everything reconcilable from git: controllers, apps, namespaces, policy        | Flux         | [`flux/`, `infra/`, `nodes/`](gitops/flux.md) |
| Standalone | The forge, on a node with no Kubernetes: Forgejo and Woodpecker CI             | Podman timer | [`nodes/brokkr.podman/`](gitops/podman.md)    |
| Cloud      | Provider APIs no Kustomization can express: DNS, OIDC clients, the mesh policy | OpenTofu     | [`tofu/`](tofu/index.md)                      |

The table says who owns what. What it cannot say is how the planes meet: each hands off to the next
exactly once, and nothing reaches back the other way. Green is this repository, the one source of
truth. Amber is a third party, the things this repository can call but never own. Purple is the
standalone plane, which reads the same repository through a mechanism of its own.

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
  secondary: {
    style: {
      stroke: mediumpurple
      fill: lavender
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
  brokkr
}

cluster: k3s cluster {
  flux: Flux
  workloads: controllers + apps
  flux -> workloads: reconciles
}

git: this repository { class: boundary }

forge: "the forge (brokkr)\nForgejo + Woodpecker" { class: secondary }

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
git -> forge: pulled by a timer on the node
hosts -> cluster: run
cluster.workloads -> cloud.pocketid: OIDC at runtime
forge -> cloud.pocketid: OIDC at runtime, degradable
```

The repository has two readers rather than one, which is the only place the "hands off exactly once"
shape does not hold. Flux is one. The forge is the other, and it is drawn apart deliberately: it
reconciles from git without Flux and without a cluster, so a cluster outage cannot take it down. That
is the entire reason it exists. See [The standalone Podman plane](gitops/podman.md).

Where to go next:

- Setting up from nothing: [Cold bootstrap](operations/setup.md).
- Something is broken: [Troubleshooting](operations/troubleshooting.md).
- Adding to the tree: [Conventions](conventions/layout.md).
- Replacing a credential: [Credential rotation](operations/rotation.md).
- Looking for a command: [Recipe reference](operations/recipes.md).

## What runs where

`kenaz` runs the k3s server, so it is both controller and worker, and it carries the tenant apps
under `nodes/kenaz.k8s/`. `ogma` is an agent and the cluster's entrypoint: it is the only node with
public ingress, so both Traefiks and Pocket ID are pinned to it with a `nodeSelector`. `brokkr` is
in no cluster and serves `git.$DOMAIN` and `ci.$DOMAIN` itself. All three are on the mesh and are
addressed by their mesh DNS name, never by a stored address. See [Nodes](ansible/nodes.md).

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
reach pods through the Infisical operator. `brokkr` reads no store at all: its secrets are files
Ansible pushed. The full rule, and what to do when you need a new one,
is in [Secrets](conventions/secrets.md). Replacing one is
[Credential rotation](operations/rotation.md).
