# The internet-facing Cilium Gateway "public" (infrastructure/base/gateway/
# public.yaml) serves HTTPS on fixed LoadBalancer addresses that Cilium
# announces over BGP. The addresses come from var.firewall_cidrs
# (public_gateway_v4, public_gateway_v6).

# The policies that open the firewall for it are in firewall_policies.tf
# (External -> External).
#
# A port forward would add an unrestricted MASQUERADE for its target, so
# Authelia would see the router for every IPv4 client. A plain DNAT keeps the
# client address. Without masquerade there is also no NAT loopback: LAN clients
# reach the Gateway through split DNS (infrastructure/base/external-dns-internal),
# not through the public address.
resource "unifi_nat" "public_gateway_https_imported" {
  description = "Public Gateway HTTPS"
  type        = "DNAT"
  protocol    = "tcp"
  ip_version  = "IPV4"
  # only the FTTH WAN (unifi_wan.internet_2, the controller's WAN2)
  in_interface = unifi_wan.internet_2.id
  ip_address   = local.firewall_cidrs.public_gateway_v4
  port         = "443"
  enabled      = true
  logging      = false

  destination_filter = {
    filter_type = "ADDRESS_AND_PORT"
    port        = "443"
  }
}
