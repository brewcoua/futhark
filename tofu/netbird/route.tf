# The k0s service CIDR, routed into the mesh by the nodes themselves. No controller inside the
# cluster registers traefik-internal as its own mesh device — the nodes are already peers, so
# they forward to the Service's ClusterIP and kube-proxy takes it from there.
#
# peer_groups rather than a single peer, so both nodes advertise it and NetBird fails the route
# over when one is down. groups is the other half and means something different: the peers that
# *receive* the route.
#
# masquerade is required, not cosmetic. Without it the reply is addressed to the client's mesh
# address, which the answering pod has no route back to.
resource "netbird_route" "k0s_services" {
  network_id  = "k0s-services"
  description = "k0s service CIDR, for traefik-internal"
  network     = local.service_cidr
  peer_groups = [netbird_group.k0s.id]
  groups      = [netbird_group.admin.id]
  masquerade  = true
  enabled     = true
}
