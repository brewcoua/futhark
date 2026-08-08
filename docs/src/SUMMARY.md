# Summary

[futhark](index.md)

# Operations

- [Cold bootstrap](operations/setup.md)
- [The rclone remotes](operations/rclone.md)
- [Backup and recovery](operations/recovery.md)
- [Recipe reference](operations/recipes.md)
- [Checks and CI](operations/checks.md)
- [Troubleshooting](operations/troubleshooting.md)

# Conventions

- [Layout and naming](conventions/layout.md)
- [Namespaces](conventions/namespaces.md)
- [Network policy](conventions/network-policy.md)
- [Secrets](conventions/secrets.md)
- [Domains](conventions/domains.md)
- [Startup ordering](conventions/ordering.md)
- [Dependency updates](conventions/updates.md)

# Ansible — the host plane

- [Inventory and roles](ansible/index.md)
- [Nodes](ansible/nodes.md)
- [Pod to mesh networking](ansible/networking.md)

# Flux — the cluster plane

- [Bootstrap and reconciliation](gitops/flux.md)
- [Cluster infrastructure](gitops/infra.md)
- [Node apps](gitops/nodes.md)

# OpenTofu — the cloud plane

- [Rules for every module](tofu/index.md)
- [bunny](tofu/bunny.md)
- [oidc](tofu/oidc.md)
- [tailscale](tofu/tailscale.md)
