# Zone-based firewall policies. The UDM (Network 11) migrated the former classic
# rules (the firewall_rule resources of earlier revisions) to zones; the policies
# are adopted by importing them (imports.tf), never recreated.
#
# Ordering: the provider cannot set a policy's `index` (it is read-only, new
# policies are appended to the end of their source/destination zone pair and
# there is no reorder API). Order is therefore only editable in the UI, and a
# pair whose policies must keep an order (allow before block) keeps the imported
# one: add new policies for such a pair only when they belong at the end.
#
# The BGP LoadBalancer addresses (the internal pool, the public Gateway) are not
# UDM networks, so traffic to them is classified Internal -> External (External ->
# External for the DNAT'd public Gateway), and the zone-based firewall drops
# ctstate INVALID there.

data "unifi_firewall_zone" "this" {
  for_each = toset(["internal", "external", "gateway", "vpn", "hotspot"])
  name     = title(each.key)
}

locals {
  # addresses of the LoadBalancer pools and the public Gateway, all from
  # var.firewall_cidrs (the public Gateway's v4 as a /32, as the policy holds it)
  lb_ips = [
    local.firewall_cidrs.lb_pool_v4,
    "${local.firewall_cidrs.public_gateway_v4}/32",
    local.firewall_cidrs.lb_pool_v6,
    local.firewall_cidrs.public_gateway_v6,
  ]

  # Key "<source zone>-<destination zone>/<slug>"; the zones are taken from it.
  # src/dst: the endpoint (matching_target and what it matches); the zone is added
  # in the resource.
  firewall_policies = {
    # External -> External: the public Gateway's LoadBalancer addresses are BGP
    # routes, not a UDM network, so the DNAT'd connection is classified
    # External -> External. A custom DNAT does not open the firewall: these accept
    # the translated HTTPS connection (IPv4 after the DNAT, IPv6 has no NAT).
    # The controller migrated the former WAN_IN / WANv6_IN rules here.
    "external-external/public-gateway-https-v4" = {
      name       = "Allow Public Gateway HTTPS IPv4"
      action     = "ALLOW"
      protocol   = "tcp"
      ip_version = "IPV4"
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.public_gateway_v4.id, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.https_ports.id }
    }
    "external-external/public-gateway-https-v6" = {
      name       = "Allow Public Gateway HTTPS IPv6"
      action     = "ALLOW"
      protocol   = "tcp"
      ip_version = "IPV6"
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.public_gateway_v6.id, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.https_ports.id }
    }

    # External -> Gateway (the UDM itself): keeps the WireGuard server (unifi/wireguard.tf)
    # reachable over IPv6; UniFi only opens the port automatically for the
    # server's ip_version (v4).
    "external-gateway/wireguard-server-v6" = {
      name       = "Allow WireGuard Server IPv6"
      action     = "ALLOW"
      protocol   = "udp"
      ip_version = "IPV6"
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.wireguard_ports.id }
    }

    # Internal -> External: everything the UDM forwards out of a LAN to an address that is
    # not a UDM network, i.e. the internet and the BGP LoadBalancer addresses.
    # Order matters (first match wins) and is only editable in the UI:
    #   established/related first, so replies to connections opened elsewhere
    #   (laptop -> plug) pass
    #   IoT -> Technitium (DNS), IoT -> mosquitto-lan (8883)
    #   IoT -> any other private address: drop
    #   NTP to the internet (Tasmota needs the time for TLS)
    #   the group iot-internet (Gardena) -> internet
    #   the rest of IoT -> anywhere: drop
    #   Work -> any private address: drop
    #   lan-to-lb (last): the zone-based firewall drops ctstate INVALID, and
    #   the LAN reaches the LoadBalancers asymmetrically (UDM -> node, the
    #   node replies directly on the LAN), so the UDM sees those flows as
    #   INVALID; this policy allows CUSTOM states including INVALID towards
    #   the LoadBalancer pools. It sits behind the IoT/Work drops, so they win.
    "internal-external/established" = {
      name       = "Allow established/related"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "IPV4"
      state_type = "RESPOND_ONLY"
      states     = ["ESTABLISHED", "RELATED"]
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "ANY" }
    }
    "internal-external/iot-dns" = {
      name       = "Allow IoT to DNS"
      action     = "ALLOW"
      protocol   = "tcp_udp"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_dns.id, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dns_ports.id }
    }
    "internal-external/iot-mqtt" = {
      name       = "Allow IoT to MQTT"
      action     = "ALLOW"
      protocol   = "tcp"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_mqtt.id, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.mqtt_ports.id }
    }
    "internal-external/iot-private" = {
      name       = "Drop IoT to private"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }
    "internal-external/iot-ntp" = {
      name       = "Allow IoT NTP"
      action     = "ALLOW"
      protocol   = "udp"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.ntp_ports.id }
    }
    "internal-external/iot-internet" = {
      name       = "Allow IoT internet group"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_internet.id }
      dst        = { matching_target = "ANY" }
    }
    "internal-external/iot-drop" = {
      name       = "Drop IoT"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "ANY" }
    }
    "internal-external/work-private" = {
      name       = "Drop Work to private"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }
    "internal-external/lan-to-lb" = {
      name       = "Allow LAN to cluster LB (asymmetric)"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "BOTH"
      state_type = "CUSTOM"
      states     = ["NEW", "INVALID", "ESTABLISHED", "RELATED"]
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "IP", ips = local.lb_ips }
    }

    # Internal -> Gateway (the UDM itself): keeps IoT off the router except DHCP, and
    # Work off it except DHCP and DNS (the router's resolver, which forwards
    # to the ISP; the Work network hands out no other).
    "internal-gateway/iot-dhcp" = {
      name       = "Allow IoT DHCP"
      action     = "ALLOW"
      protocol   = "udp"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dhcp_ports.id }
    }
    "internal-gateway/iot-router-drop" = {
      name       = "Drop IoT to router"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "ANY" }
    }
    "internal-gateway/work-dhcp" = {
      name       = "Allow Work DHCP"
      action     = "ALLOW"
      protocol   = "udp"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
      dst        = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dhcp_ports.id }
    }
    "internal-gateway/work-dns" = {
      name       = "Allow Work DNS"
      action     = "ALLOW"
      protocol   = "tcp_udp"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
      dst        = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dns_ports.id }
    }
    "internal-gateway/work-router-drop" = {
      name       = "Drop Work to router"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
      dst        = { matching_target = "ANY" }
    }

    # Internal -> Internal (LAN to LAN, routed by the UDM):
    #   established/related first, so replies still pass
    #   the IoT admins may open connections into IoT
    #   IoT -> any private address: drop (DNS/MQTT/NTP exceptions are in
    #   internal-external, which is where their addresses are classified)
    #   Work -> any private address and anything into Work: drop
    "internal-internal/established" = {
      name       = "Allow established/related"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "IPV4"
      state_type = "RESPOND_ONLY"
      states     = ["ESTABLISHED", "RELATED"]
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "ANY" }
    }
    "internal-internal/iot-admins" = {
      name       = "Allow IoT admins to IoT"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_admins.id }
      dst        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
    }
    "internal-internal/iot-private" = {
      name       = "Drop IoT to private"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }
    "internal-internal/work-private" = {
      name       = "Drop Work to private"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }
    "internal-internal/into-work" = {
      name       = "Drop into Work"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
    }

    # Internal -> Vpn (the WireGuard tunnel subnet): same drops as towards the LANs,
    # so IoT and Work cannot open connections to tunnel clients.
    "internal-vpn/established" = {
      name       = "Allow established/related"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "IPV4"
      state_type = "RESPOND_ONLY"
      states     = ["ESTABLISHED", "RELATED"]
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "ANY" }
    }
    "internal-vpn/iot-private" = {
      name       = "Drop IoT to private"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.iot.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }
    "internal-vpn/work-private" = {
      name       = "Drop Work to private"
      action     = "BLOCK"
      protocol   = "all"
      ip_version = "IPV4"
      src        = { matching_target = "NETWORK", network_ids = [unifi_network.work.id] }
      dst        = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }

    # Vpn -> External: the WireGuard clients' GUA /64 (firewall group wireguard_home_v6) gets
    # out to the internet over IPv6 without NAT66.
    "vpn-external/wireguard-home-v6" = {
      name       = "Wireguard ipv6"
      action     = "ALLOW"
      protocol   = "all"
      ip_version = "IPV6"
      src        = { matching_target = "IP", ip_group_id = unifi_firewall_group.wireguard_home_v6.id }
      dst        = { matching_target = "ANY" }
    }
  }

  # Mechanical copies the migration made of the policies above into every other
  # zone pair that can never match any traffic (e.g. Internal -> Hotspot: there is
  # no Hotspot network). They are imported so that the next commit can remove them
  # (which destroys them); nothing else uses them.
  legacy_duplicates = {
    "external-external/wireguard-home-v6"       = local.firewall_policies["vpn-external/wireguard-home-v6"]
    "external-hotspot/public-gateway-https-v4"  = local.firewall_policies["external-external/public-gateway-https-v4"]
    "external-hotspot/public-gateway-https-v6"  = local.firewall_policies["external-external/public-gateway-https-v6"]
    "external-internal/public-gateway-https-v4" = local.firewall_policies["external-external/public-gateway-https-v4"]
    "external-internal/public-gateway-https-v6" = local.firewall_policies["external-external/public-gateway-https-v6"]
    "external-vpn/public-gateway-https-v4"      = local.firewall_policies["external-external/public-gateway-https-v4"]
    "external-vpn/public-gateway-https-v6"      = local.firewall_policies["external-external/public-gateway-https-v6"]
    "hotspot-external/wireguard-home-v6"        = local.firewall_policies["vpn-external/wireguard-home-v6"]
    "internal-external/wireguard-home-v6"       = local.firewall_policies["vpn-external/wireguard-home-v6"]
    "internal-hotspot/established"              = local.firewall_policies["internal-external/established"]
    "internal-hotspot/iot-dns"                  = local.firewall_policies["internal-external/iot-dns"]
    "internal-hotspot/iot-drop"                 = local.firewall_policies["internal-external/iot-drop"]
    "internal-hotspot/iot-internet"             = local.firewall_policies["internal-external/iot-internet"]
    "internal-hotspot/iot-mqtt"                 = local.firewall_policies["internal-external/iot-mqtt"]
    "internal-hotspot/iot-ntp"                  = local.firewall_policies["internal-external/iot-ntp"]
    "internal-hotspot/iot-private"              = local.firewall_policies["internal-external/iot-private"]
    "internal-hotspot/work-private"             = local.firewall_policies["internal-external/work-private"]
    "internal-internal/iot-dns"                 = local.firewall_policies["internal-external/iot-dns"]
    "internal-internal/iot-drop"                = local.firewall_policies["internal-external/iot-drop"]
    "internal-internal/iot-internet"            = local.firewall_policies["internal-external/iot-internet"]
    "internal-internal/iot-mqtt"                = local.firewall_policies["internal-external/iot-mqtt"]
    "internal-internal/iot-ntp"                 = local.firewall_policies["internal-external/iot-ntp"]
    "internal-vpn/iot-dns"                      = local.firewall_policies["internal-external/iot-dns"]
    "internal-vpn/iot-drop"                     = local.firewall_policies["internal-external/iot-drop"]
    "internal-vpn/iot-internet"                 = local.firewall_policies["internal-external/iot-internet"]
    "internal-vpn/iot-mqtt"                     = local.firewall_policies["internal-external/iot-mqtt"]
    "internal-vpn/iot-ntp"                      = local.firewall_policies["internal-external/iot-ntp"]
  }
}

resource "unifi_firewall_policy" "this" {
  for_each = local.firewall_policies

  name       = each.value.name
  action     = each.value.action
  protocol   = each.value.protocol
  ip_version = each.value.ip_version

  connection_state_type = try(each.value.state_type, null)
  connection_states     = try(each.value.states, null)

  source      = merge({ zone_id = data.unifi_firewall_zone.this[split("-", split("/", each.key)[0])[0]].id }, each.value.src)
  destination = merge({ zone_id = data.unifi_firewall_zone.this[split("-", split("/", each.key)[0])[1]].id }, each.value.dst)
}

resource "unifi_firewall_policy" "legacy_duplicate" {
  for_each = local.legacy_duplicates

  name       = each.value.name
  action     = each.value.action
  protocol   = each.value.protocol
  ip_version = each.value.ip_version

  connection_state_type = try(each.value.state_type, null)
  connection_states     = try(each.value.states, null)

  source      = merge({ zone_id = data.unifi_firewall_zone.this[split("-", split("/", each.key)[0])[0]].id }, each.value.src)
  destination = merge({ zone_id = data.unifi_firewall_zone.this[split("-", split("/", each.key)[0])[1]].id }, each.value.dst)
}
