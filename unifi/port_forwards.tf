# The internet-facing Cilium Gateway "public" (infrastructure/base/gateway/
# public.yaml) serves HTTPS on fixed LoadBalancer addresses that Cilium
# announces over BGP. The addresses come from var.firewall_cidrs
# (public_gateway_v4, public_gateway_v6).

resource "unifi_port_forward" "public_gateway_https" {
  name     = "Public Gateway HTTPS"
  protocol = "tcp"
  # created disabled by the provider unless set explicitly
  enabled = true
  logging = false

  wan = {
    # only the FTTH WAN (unifi_wan.internet_2, the controller's WAN2); its
    # single fixed IPv4 makes ip_address (default any) unnecessary
    interface = lower(unifi_wan.internet_2.networkgroup)
    port      = "443"
  }
  forward = {
    ip   = local.firewall_cidrs.public_gateway_v4
    port = "443"
  }
}

# IPv6 has no NAT: WANv6_IN must accept the connection. Index 25000 is in the
# user range that is evaluated before UniFi's built-in drop of unsolicited
# WANv6_IN traffic (same as the WireGuard rules in firewall_rules.tf). No state
# match, see the note there on the provider not sending state flags on create.
resource "unifi_firewall_rule" "allow_public_gateway_v6" {
  name                    = "Allow Public Gateway HTTPS IPv6"
  action                  = "accept"
  ruleset                 = "WANv6_IN"
  rule_index              = 25000
  protocol_v6             = "tcp"
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source = {
    network_type = "NETv4"
  }
  destination = {
    network_type = "NETv4"
    firewall_group_ids = [
      unifi_firewall_group.public_gateway_v6.id,
      unifi_firewall_group.https_ports.id,
    ]
  }
  state = {
    established = false
    invalid     = false
    new         = false
    related     = false
  }
}
