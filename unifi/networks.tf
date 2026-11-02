# The three LANs. Addresses come from var.networks (Secret unifi-vars).

resource "unifi_network" "default" {
  name        = "Default"
  purpose     = "corporate"
  vlan        = null
  subnet      = local.networks.default.subnet
  domain_name = local.networks.default.domain_name
  auto_scale  = false
  lte_lan     = true

  dhcp_server = {
    enabled           = true
    start             = local.networks.default.dhcp_start
    stop              = local.networks.default.dhcp_stop
    leasetime         = "24h0m0s"
    conflict_checking = true
    dns = {
      enabled = local.networks.default.dhcp_dns != null
      servers = local.networks.default.dhcp_dns
    }
  }

  # The DHCPv6 server stays off (clients use SLAAC); its DNS servers are the
  # ones the router advertises (RDNSS), i.e. Technitium.
  dhcp_v6_server = {
    enabled = false
    lease   = 86400
    start   = "::2"
    stop    = "::7d1"
    dns = {
      auto    = false
      servers = local.networks.default.dhcp_v6_dns
    }
  }

  ipv6 = {
    interface_type            = "pd"
    client_address_assignment = "slaac"
    pd = {
      # FTTH's delegated /56; the prefix ID is pinned so moving the WAN keeps
      # the LAN's /64 (lanSubnetV6, the BGP peer address, the firewall groups).
      # The UDM does not map the ID to the subnet byte one to one: measured,
      # "0" gives <prefix>01::/64 and "1" gives <prefix>00::/64.
      interface             = lower(unifi_wan.internet_2.networkgroup)
      auto_prefixid_enabled = false
      prefixid              = "1" # step A of the swap; target "0"
      start                 = "::2"
      stop                  = "::7d1"
    }
    ra = {
      enabled            = true
      preferred_lifetime = "4h0m0s"
      priority           = "high"
    }
  }
}

resource "unifi_network" "homelab" {
  name        = "homelab"
  purpose     = "corporate"
  vlan        = 2
  subnet      = local.networks.homelab.subnet
  domain_name = local.networks.homelab.domain_name
  auto_scale  = false
  lte_lan     = true

  dhcp_server = {
    enabled           = true
    start             = local.networks.homelab.dhcp_start
    stop              = local.networks.homelab.dhcp_stop
    leasetime         = "24h0m0s"
    conflict_checking = true
    dns = {
      enabled = local.networks.homelab.dhcp_dns != null
      servers = local.networks.homelab.dhcp_dns
    }
  }

  ipv6 = {
    interface_type            = "pd"
    client_address_assignment = "slaac"
    pd = {
      # FTTH's delegated /56; the prefix ID is pinned so moving the WAN keeps
      # the LAN's /64 (lanSubnetV6, the BGP peer address, the firewall groups).
      # The UDM does not map the ID to the subnet byte one to one: measured,
      # "0" gives <prefix>01::/64 and "1" gives <prefix>00::/64.
      interface             = lower(unifi_wan.internet_2.networkgroup)
      auto_prefixid_enabled = false
      prefixid              = "2" # step A of the swap: temporary, target "1"
      start                 = "::2"
      stop                  = "::7d1"
    }
    ra = {
      enabled            = true
      preferred_lifetime = "4h0m0s"
      priority           = "high"
    }
  }
}

# IoT: corporate rather than guest, so the LAN_IN rules in firewall_rules.tf
# alone decide what it reaches (Technitium, MQTT, NTP; internet only for the
# group iot-internet). No IPv6, so the rules are IPv4 only.
resource "unifi_network" "iot" {
  name        = "IoT"
  purpose     = "corporate"
  vlan        = 100
  subnet      = local.networks.iot.subnet
  domain_name = local.networks.iot.domain_name
  auto_scale  = true
  lte_lan     = false

  dhcp_server = {
    enabled           = true
    start             = local.networks.iot.dhcp_start
    stop              = local.networks.iot.dhcp_stop
    leasetime         = "24h0m0s"
    conflict_checking = false
    dns = {
      enabled = local.networks.iot.dhcp_dns != null
      servers = local.networks.iot.dhcp_dns
    }
  }

  ipv6 = {
    interface_type = "none"
  }
}
