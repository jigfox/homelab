# Legacy (non zone-based) firewall rules. The controller still uses the classic
# firewall: no zones, no zone policies and no port forwards exist, so only these
# two rules are managed.

# Keeps the WireGuard server (unifi/wireguard.tf) reachable over IPv6: UniFi only
# opens the port automatically for the server's ip_version (v4).
resource "unifi_firewall_rule" "allow_wireguard_ports" {
  name                    = "Allow WireGuard Server IPv6"
  action                  = "accept"
  ruleset                 = "WANv6_LOCAL"
  rule_index              = 25000
  protocol_v6             = "udp"
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source = {
    network_type = "NETv4"
  }
  destination = {
    network_type       = "NETv4"
    firewall_group_ids = [unifi_firewall_group.wireguard_ports.id]
  }
  state = {
    established = false
    invalid     = false
    new         = false
    related     = false
  }
}

resource "unifi_firewall_rule" "allow_wireguard_home_v6" {
  name                    = "Wireguard ipv6"
  action                  = "accept"
  ruleset                 = "WANv6_OUT"
  rule_index              = 25000
  protocol_v6             = "all"
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source = {
    network_type       = "NETv4"
    firewall_group_ids = [unifi_firewall_group.wireguard_home_v6.id]
  }
  destination = {
    network_type = "NETv4"
  }
  state = {
    established = false
    invalid     = false
    new         = false
    related     = false
  }
}
