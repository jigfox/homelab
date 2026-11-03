# The internet-facing Cilium Gateway "public" (infrastructure/base/gateway/
# public.yaml) serves HTTPS on fixed LoadBalancer addresses that Cilium
# announces over BGP. The addresses come from var.firewall_cidrs
# (public_gateway_v4, public_gateway_v6).

# A port forward would add an unrestricted MASQUERADE for its target, so
# Authelia would see the router for every IPv4 client. A plain DNAT keeps the
# client address. Without masquerade there is also no NAT loopback: LAN clients
# reach the Gateway through split DNS (infrastructure/base/external-dns-internal),
# not through the public address.
resource "unifi_nat" "public_gateway_https" {
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

# A custom DNAT does not open the firewall: WAN_IN must accept the translated
# connection. Index 20000: IPv4 rules take 20000+, 25000 is the IPv6 range
# (api.err.FirewallRuleIndexOutOfRange). No state match (see the
# note there).
resource "unifi_firewall_rule" "allow_public_gateway_v4" {
  name                    = "Allow Public Gateway HTTPS IPv4"
  action                  = "accept"
  ruleset                 = "WAN_IN"
  rule_index              = 20000
  protocol                = "tcp"
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
      unifi_firewall_group.public_gateway_v4.id,
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
