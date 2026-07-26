# Namespaces

Infra controllers declare their own namespace, in `infra/<component>/app/namespace.yaml`.

Node and tenant namespaces are centralized instead, under
`infra/configs/namespaces/<namespace>/`, alongside that namespace's
[NetworkPolicy and RBAC](network-policy.md). The split exists because a tenant namespace
needs policy attached to it that the app itself should not own.

Every non-control-plane namespace carries `futk.eu/tier: infra` or `futk.eu/tier: node`, and
node namespaces add `futk.eu/node: <hostname>`. Those labels mirror OpenBao's own namespace
split into `infra` and `node-<hostname>`, created by
`ansible/roles/openbao/tasks/namespaces.yml` — the two need to stay in step, since a node's
apps read from the OpenBao namespace named after the node.
