# Namespaces

Infra controllers declare their own namespace, in `infra/<component>/app/namespace.yaml`.

Node and tenant namespaces are centralized instead, under
`infra/configs/namespaces/<namespace>/`, alongside that namespace's
[NetworkPolicy and RBAC](network-policy.md). The split exists because a tenant namespace
needs policy attached to it that the app itself should not own.

Every non-control-plane namespace carries `futk.eu/tier: infra` or `futk.eu/tier: node`, and
node namespaces add `futk.eu/node: <hostname>`.

Those labels are load-bearing, not documentation. The `ValidatingAdmissionPolicy` in
`infra/infisical-operator/config/` reads them to decide which Infisical path a namespace may
pull from, so a namespace with the wrong label reads the wrong tier's secrets, and one with no
label cannot host an `InfisicalStaticSecret` at all. See
[Secrets](secrets.md#infisical-and-how-tier-isolation-is-enforced).
