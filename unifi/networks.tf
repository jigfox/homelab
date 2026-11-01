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
    dns               = {
      enabled = local.networks.default.dhcp_dns != null
      servers = local.networks.default.dhcp_dns
    }
  }

  ipv6 = {
    interface_type            = "pd"
    client_address_assignment = "slaac"
    pd = {
      interface             = "wan3"
      auto_prefixid_enabled = true
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
    dns               = {
      enabled = local.networks.homelab.dhcp_dns != null
      servers = local.networks.homelab.dhcp_dns
    }
  }

  ipv6 = {
    interface_type            = "pd"
    client_address_assignment = "slaac"
    pd = {
      interface             = "wan3"
      auto_prefixid_enabled = true
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

resource "unifi_network" "iot" {
  name        = "IoT"
  purpose     = "guest"
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
    dns               = {
      enabled = local.networks.iot.dhcp_dns != null
      servers = local.networks.iot.dhcp_dns
    }
  }

  ipv6 = {
    interface_type = "none"
  }
}
