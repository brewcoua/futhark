# Namespaces

Every `Namespace` CR lives in `infra/namespaces/app/namespaces.yaml`, owned by the `namespaces`
Kustomization, which depends on nothing. Components do not declare their own — a controller
whose chart writes into a namespace it does not own would otherwise deadlock against the
component that does. See [Startup ordering](ordering.md).

What stays per-namespace is the policy attached to it: `infra/policies/namespaces/<namespace>/`
holds that namespace's [NetworkPolicy and RBAC](network-policy.md), not its `Namespace`.

Every non-control-plane namespace carries `futk.eu/tier: infra` or `futk.eu/tier: node`, and
node namespaces add `futk.eu/node: <hostname>`.

Those labels are load-bearing, not documentation. The `ValidatingAdmissionPolicy` in
`infra/infisical-operator/config/` reads them to decide which Infisical path a namespace may
pull from, so a namespace with the wrong label reads the wrong tier's secrets, and one with no
label cannot host an `InfisicalStaticSecret` at all. See
[Secrets](secrets.md#infisical-and-how-tier-isolation-is-enforced).
