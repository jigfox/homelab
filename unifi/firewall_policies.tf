# Zone-based firewall policies. The UDM (Network 11) migrated the former classic
# rules (the firewall_rule resources of earlier revisions) to zones; the policies
# were adopted by import from the migration, never recreated.
#
# Ordering: the provider cannot set a policy's `index` (it is read-only); new
# policies are appended to the end of their source/destination zone pair and
# reordering is only possible in the UI. A pair whose policies must keep an order
# (allow before block) therefore only gets new policies that belong at the end.
#
# The BGP LoadBalancer addresses (the internal pool, the public Gateway) are not
# UDM networks, so traffic to them is classified Internal -> External (External ->
# External for the DNAT'd public Gateway), and the zone-based firewall drops
# ctstate INVALID there.

data "unifi_firewall_zone" "this" {
  for_each = toset(["internal", "external", "gateway", "vpn"])
  name     = title(each.key)
}

locals {
  # zone name (lowercase) -> id: the predefined zones and the custom ones (firewall_zones.tf)
  zone_ids = merge(
    { for k, z in data.unifi_firewall_zone.this : k => z.id },
    { for k, z in unifi_firewall_zone.this : k => z.id },
  )

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

  # New zone pairs around the custom zones IoT and Work (firewall_zones.tf).
  # Controller defaults (predefined, custom policies are evaluated first):
  # Block All into IoT from Internal/Vpn/External and from IoT to Internal, Vpn,
  # Work and IoT, plus every pair into and out of Work; Allow All for IoT/Work to
  # External and Gateway. IoT -> Internal and IoT -> Vpn have no allow-return default.
  #
  # Ordering: a new policy is appended to the end of its pair and for_each creates
  # instances in parallel, so the policies are split into two resources: every
  # "allow" tier policy (zone_allow) exists before any "block" tier policy
  # (zone_block, depends_on zone_allow), hence allows precede blocks in every pair.
  # Within a tier the order must not matter, so each policy is precise on its own
  # (e.g. match_opposite_ips instead of relying on a preceding private-address drop).
  # Maintenance rule: a new ALLOW in a pair that already holds a BLOCK lands after
  # it and never matches. Then recreate that pair's blocks (`tofu apply -replace=
  # 'unifi_firewall_policy.zone_block["<key>"]'`, appended at the end) or reorder
  # in the UI. Key "<source zone>-<destination zone>/<slug>", as above.
  zone_policies = {
    # IoT -> External: the internet and the LoadBalancer addresses. DNS to
    # Technitium, MQTT to mosquitto-lan, NTP and the iot-internet group to
    # non-private addresses only; the rest of IoT is dropped. Source ANY: the
    # zone is the IoT network, and the controller rejects a NETWORK source that
    # is not in the policy's zone (FirewallPolicySourceMatchingTargetNotApplicableForZone).
    "iot-external/iot-dns" = {
      name     = "Allow IoT to DNS (IoT zone)"
      tier     = "ALLOW"
      protocol = "tcp_udp"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_dns.id, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dns_ports.id }
    }
    "iot-external/iot-mqtt" = {
      name     = "Allow IoT to MQTT (IoT zone)"
      tier     = "ALLOW"
      protocol = "tcp"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_mqtt.id, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.mqtt_ports.id }
    }
    "iot-external/iot-ntp" = {
      name     = "Allow IoT NTP (IoT zone)"
      tier     = "ALLOW"
      protocol = "udp"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id, match_opposite_ips = true, port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.ntp_ports.id }
    }
    "iot-external/iot-internet" = {
      name     = "Allow IoT internet group (IoT zone)"
      tier     = "ALLOW"
      protocol = "all"
      src      = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_internet.id }
      dst      = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id, match_opposite_ips = true }
    }
    "iot-external/iot-drop" = {
      name     = "Drop IoT (IoT zone)"
      tier     = "BLOCK"
      protocol = "all"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY" }
    }

    # IoT -> Gateway (the UDM itself): DHCP only.
    "iot-gateway/iot-dhcp" = {
      name     = "Allow IoT DHCP (IoT zone)"
      tier     = "ALLOW"
      protocol = "udp"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dhcp_ports.id }
    }
    "iot-gateway/iot-router-drop" = {
      name     = "Drop IoT to router (IoT zone)"
      tier     = "BLOCK"
      protocol = "all"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY" }
    }

    # IoT -> Internal / Vpn: replies to connections the IoT admins open into IoT
    # (the zone default has no allow-return there); new connections stay blocked.
    "iot-internal/iot-return" = {
      name       = "Allow IoT replies (IoT zone)"
      tier       = "ALLOW"
      protocol   = "all"
      state_type = "RESPOND_ONLY"
      states     = ["ESTABLISHED", "RELATED"]
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "ANY" }
    }
    "iot-vpn/iot-return" = {
      name       = "Allow IoT replies (IoT zone)"
      tier       = "ALLOW"
      protocol   = "all"
      state_type = "RESPOND_ONLY"
      states     = ["ESTABLISHED", "RELATED"]
      src        = { matching_target = "ANY" }
      dst        = { matching_target = "ANY" }
    }

    # Internal -> IoT and Vpn -> IoT (the WireGuard tunnel subnet is in the group):
    # only the IoT admins may open connections into IoT. Internal -> IoT logs the
    # rest, to spot devices that relied on the old open access.
    "internal-iot/iot-admins" = {
      name     = "Allow IoT admins to IoT (IoT zone)"
      tier     = "ALLOW"
      protocol = "all"
      src      = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_admins.id }
      dst      = { matching_target = "ANY" }
    }
    "internal-iot/iot-other" = {
      name     = "Block other Internal to IoT"
      tier     = "BLOCK"
      protocol = "all"
      logging  = true
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY" }
    }
    "vpn-iot/iot-admins" = {
      name     = "Allow IoT admins to IoT (IoT zone)"
      tier     = "ALLOW"
      protocol = "all"
      src      = { matching_target = "IP", ip_group_id = unifi_firewall_group.iot_admins.id }
      dst      = { matching_target = "ANY" }
    }

    # Work -> External: everything except private addresses stays allowed by the zone
    # default. Work -> Gateway: DHCP and DNS only (the router's resolver forwards to
    # the ISP; Work hands out no other).
    "work-external/work-private" = {
      name     = "Drop Work to private (Work zone)"
      tier     = "BLOCK"
      protocol = "all"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "IP", ip_group_id = unifi_firewall_group.private_v4.id }
    }
    "work-gateway/work-dhcp" = {
      name     = "Allow Work DHCP (Work zone)"
      tier     = "ALLOW"
      protocol = "udp"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dhcp_ports.id }
    }
    "work-gateway/work-dns" = {
      name     = "Allow Work DNS (Work zone)"
      tier     = "ALLOW"
      protocol = "tcp_udp"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY", port_matching_type = "OBJECT", port_group_id = unifi_firewall_group.dns_ports.id }
    }
    "work-gateway/work-router-drop" = {
      name     = "Drop Work to router (Work zone)"
      tier     = "BLOCK"
      protocol = "all"
      src      = { matching_target = "ANY" }
      dst      = { matching_target = "ANY" }
    }
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

  source      = merge({ zone_id = local.zone_ids[split("-", split("/", each.key)[0])[0]] }, each.value.src)
  destination = merge({ zone_id = local.zone_ids[split("-", split("/", each.key)[0])[1]] }, each.value.dst)
}

resource "unifi_firewall_policy" "zone_allow" {
  for_each = { for k, v in local.zone_policies : k => v if v.tier == "ALLOW" }

  name       = each.value.name
  action     = "ALLOW"
  protocol   = each.value.protocol
  ip_version = "IPV4"

  connection_state_type = try(each.value.state_type, null)
  connection_states     = try(each.value.states, null)

  source      = merge({ zone_id = local.zone_ids[split("-", split("/", each.key)[0])[0]] }, each.value.src)
  destination = merge({ zone_id = local.zone_ids[split("-", split("/", each.key)[0])[1]] }, each.value.dst)
}

resource "unifi_firewall_policy" "zone_block" {
  for_each   = { for k, v in local.zone_policies : k => v if v.tier == "BLOCK" }
  depends_on = [unifi_firewall_policy.zone_allow]

  name       = each.value.name
  action     = "BLOCK"
  protocol   = each.value.protocol
  ip_version = "IPV4"
  logging    = try(each.value.logging, null)

  source      = merge({ zone_id = local.zone_ids[split("-", split("/", each.key)[0])[0]] }, each.value.src)
  destination = merge({ zone_id = local.zone_ids[split("-", split("/", each.key)[0])[1]] }, each.value.dst)
}
