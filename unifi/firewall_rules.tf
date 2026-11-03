# Legacy (non zone-based) firewall rules. The controller still uses the classic
# firewall: no zones and no zone policies exist (NAT and the public Gateway rules: port_forwards.tf).

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

# IoT network (VLAN 100). LAN_IN sees every packet the router forwards out of
# a LAN, to other LANs and to the internet alike, first match wins:
#   20000 replies to connections opened elsewhere (laptop -> plug) pass
#   20001 the IoT admins may open connections into IoT
#   20002 IoT -> Technitium (DNS), 20003 IoT -> mosquitto-lan (8883)
#   20004 IoT -> any other private address: drop
#   20005 NTP to the internet (Tasmota needs the time for TLS)
#   20006 the group iot-internet (Gardena) -> internet
#   20007 the rest of IoT -> anywhere: drop
# LAN_LOCAL keeps IoT off the router itself except DHCP.
# Provider 0.64.0 does not send the state flags on create (the controller then
# holds them false and the apply fails as "inconsistent result"): a new rule
# with a state match needs them set once via the API (PUT rest/firewallrule)
# and `tofu untaint`; reading them back works (updates untested).
locals {
  iot_lan_in = {
    established = {
      index = 20000, name = "Allow established/related", action = "accept", protocol = "all"
      src   = {}, dst = {}, state = { established = true, related = true }
    }
    admins = {
      index = 20001, name = "Allow IoT admins to IoT", action = "accept", protocol = "all"
      src   = { firewall_group_ids = [unifi_firewall_group.iot_admins.id] }
      dst   = { network_id = unifi_network.iot.id }
    }
    dns = {
      index = 20002, name = "Allow IoT to DNS", action = "accept", protocol = "tcp_udp"
      src   = { network_id = unifi_network.iot.id }
      dst   = { firewall_group_ids = [unifi_firewall_group.iot_dns.id, unifi_firewall_group.dns_ports.id] }
    }
    mqtt = {
      index = 20003, name = "Allow IoT to MQTT", action = "accept", protocol = "tcp"
      src   = { network_id = unifi_network.iot.id }
      dst   = { firewall_group_ids = [unifi_firewall_group.iot_mqtt.id, unifi_firewall_group.mqtt_ports.id] }
    }
    private = {
      index = 20004, name = "Drop IoT to private", action = "drop", protocol = "all"
      src   = { network_id = unifi_network.iot.id }
      dst   = { firewall_group_ids = [unifi_firewall_group.private_v4.id] }
    }
    ntp = {
      index = 20005, name = "Allow IoT NTP", action = "accept", protocol = "udp"
      src   = { network_id = unifi_network.iot.id }
      dst   = { firewall_group_ids = [unifi_firewall_group.ntp_ports.id] }
    }
    internet = {
      index = 20006, name = "Allow IoT internet group", action = "accept", protocol = "all"
      src   = { firewall_group_ids = [unifi_firewall_group.iot_internet.id] }
      dst   = {}
    }
    rest = {
      index = 20007, name = "Drop IoT", action = "drop", protocol = "all"
      src   = { network_id = unifi_network.iot.id }
      dst   = {}
    }
  }
}

resource "unifi_firewall_rule" "iot_lan_in" {
  for_each = local.iot_lan_in

  name                    = each.value.name
  action                  = each.value.action
  ruleset                 = "LAN_IN"
  rule_index              = each.value.index
  protocol                = each.value.protocol
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source      = merge({ network_type = "NETv4" }, each.value.src)
  destination = merge({ network_type = "NETv4" }, each.value.dst)
  state       = merge({ established = false, invalid = false, new = false, related = false }, try(each.value.state, {}))
}

resource "unifi_firewall_rule" "iot_local_dhcp" {
  name                    = "Allow IoT DHCP"
  action                  = "accept"
  ruleset                 = "LAN_LOCAL"
  rule_index              = 20000
  protocol                = "udp"
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source = {
    network_type = "NETv4"
    network_id   = unifi_network.iot.id
  }
  destination = {
    network_type       = "NETv4"
    firewall_group_ids = [unifi_firewall_group.dhcp_ports.id]
  }
  state = {
    established = false
    invalid     = false
    new         = false
    related     = false
  }
}

resource "unifi_firewall_rule" "iot_local_drop" {
  name                    = "Drop IoT to router"
  action                  = "drop"
  ruleset                 = "LAN_LOCAL"
  rule_index              = 20001
  protocol                = "all"
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source = {
    network_type = "NETv4"
    network_id   = unifi_network.iot.id
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

# Work network (VLAN 3, networks.tf): internet only, in both directions.
# LAN_IN (after the established/related rule 20000, so replies still pass)
#   20100 work -> any private address (every other VLAN, the LoadBalancer and
#         VPN subnets, the public Gateway behind the DNAT): drop
#   20101 anything routed into work: drop
# LAN_LOCAL keeps it off the router itself except DHCP and DNS (the router's
# resolver, which forwards to the ISP; the network hands out no other).
locals {
  work_lan_in = {
    to_private = {
      index = 20100, name = "Drop Work to private"
      src   = { network_id = unifi_network.work.id }
      dst   = { firewall_group_ids = [unifi_firewall_group.private_v4.id] }
    }
    from_any = {
      index = 20101, name = "Drop into Work"
      src   = {}
      dst   = { network_id = unifi_network.work.id }
    }
  }
  work_lan_local = {
    dhcp = { index = 20100, name = "Allow Work DHCP", action = "accept", protocol = "udp", ports = unifi_firewall_group.dhcp_ports.id }
    dns  = { index = 20101, name = "Allow Work DNS", action = "accept", protocol = "tcp_udp", ports = unifi_firewall_group.dns_ports.id }
    rest = { index = 20102, name = "Drop Work to router", action = "drop", protocol = "all", ports = null }
  }
}

resource "unifi_firewall_rule" "work_lan_in" {
  for_each = local.work_lan_in

  name                    = each.value.name
  action                  = "drop"
  ruleset                 = "LAN_IN"
  rule_index              = each.value.index
  protocol                = "all"
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source      = merge({ network_type = "NETv4" }, each.value.src)
  destination = merge({ network_type = "NETv4" }, each.value.dst)
  state       = { established = false, invalid = false, new = false, related = false }
}

resource "unifi_firewall_rule" "work_lan_local" {
  for_each = local.work_lan_local

  name                    = each.value.name
  action                  = each.value.action
  ruleset                 = "LAN_LOCAL"
  rule_index              = each.value.index
  protocol                = each.value.protocol
  setting_preference      = "auto"
  enabled                 = true
  logging                 = false
  protocol_match_excepted = false

  source = {
    network_type = "NETv4"
    network_id   = unifi_network.work.id
  }
  destination = {
    network_type       = "NETv4"
    firewall_group_ids = each.value.ports == null ? null : [each.value.ports]
  }
  state = { established = false, invalid = false, new = false, related = false }
}
