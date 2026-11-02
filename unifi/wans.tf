# The four WAN uplinks. Structure in HCL; the PPPoE credentials and the ISP
# display name of `cable` come from var.wans (Secret unifi-vars).

resource "unifi_wan" "ftth" {
  name               = "FTTH"
  enabled            = true
  networkgroup       = "WAN3"
  setting_preference = "manual"
  type               = "pppoe"
  type_v6            = "dhcpv6"
  username           = local.wans.ftth.username
  # `password`, not `password_wo`: the controller never returns it, so the
  # provider keeps the configured value and a change in unifi-vars shows up as a
  # diff. password_wo would be sent on every update but never diff, so a new
  # password would only go out by accident. The value sits in the (in-cluster)
  # state, like the WireGuard and PPSK keys.
  password = local.wans.ftth.password
  vlan = {
    enabled = true
  }
  ipv6_setting_preference = "manual"
  dhcpv6 = {
    cos = 0
    pd = {
      size      = 56
      size_auto = false
    }
    wan_delegation_type = "pd"
  }
  dns = {
    preference = "auto"
    ipv6 = {
      preference = "auto"
    }
  }
  dslite = {
    remote_host_auto = false
  }
  igmp_proxy = {
    downstream             = "none"
    downstream_network_ids = []
    upstream               = false
  }
  interface_mtu_enabled = false
  load_balance = {
    failover_priority = 1
    type              = "weighted"
    weight            = 50
  }
  mac_override_enabled = false
  provider_capabilities = {
    download_kilobits_per_second = 300000
    upload_kilobits_per_second   = 150000
  }
  report_wan_event   = false
  single_network_lan = ""
}

resource "unifi_wan" "cable" {
  name               = local.wans.cable.name
  enabled            = true
  networkgroup       = "WAN"
  setting_preference = "manual"
  type               = "dhcp"
  type_v6            = "dhcpv6"
  vlan = {
    enabled = false
  }
  ipv6_setting_preference = "manual"
  dhcpv6 = {
    pd = {
      size      = 56
      size_auto = false
    }
    wan_delegation_type = "pd"
  }
  dns = {
    preference = "auto"
    ipv6 = {
      preference = "auto"
    }
  }
  dslite = {
    remote_host      = ""
    remote_host_auto = false
  }
  igmp_proxy = {
    downstream             = "none"
    downstream_network_ids = []
    upstream               = false
  }
  interface_mtu_enabled = false
  load_balance = {
    failover_priority = 2
    type              = "failover-only"
    weight            = 99
  }
  mac_override_enabled = false
  provider_capabilities = {
    download_kilobits_per_second = 538000
    upload_kilobits_per_second   = 49000
  }
  report_wan_event   = false
  single_network_lan = ""
}

# WAN2 is the controller's built-in second WAN (cannot be deleted). It takes
# over FTTH so the port forward (provider: only wan, wan2, both) can target it:
# configured here first while no port is assigned to WAN2, then port 10 moves
# from WAN3 to WAN2 in the UI, then the old WAN3 network goes. Same settings as
# `ftth`, except the name and the failover position, until the port moves.
resource "unifi_wan" "internet_2" {
  name         = "FTTH WAN2"
  enabled      = true
  networkgroup = "WAN2"
  # the controller keeps "auto" here (and returns no single_network_lan), so
  # setting "manual" fails the apply as "inconsistent result"
  setting_preference = "auto"
  type               = "pppoe"
  type_v6            = "dhcpv6"
  username           = local.wans.ftth.username
  password           = local.wans.ftth.password
  vlan = {
    enabled = true
    id      = 7
  }
  ipv6_setting_preference = "manual"
  dhcpv6 = {
    cos = 0
    pd = {
      size      = 56
      size_auto = false
    }
    wan_delegation_type = "pd"
  }
  dns = {
    preference = "auto"
    ipv6 = {
      preference = "auto"
    }
  }
  dslite = {
    remote_host_auto = false
  }
  igmp_proxy = {
    downstream             = "none"
    downstream_network_ids = []
    upstream               = false
  }
  interface_mtu_enabled = false
  load_balance = {
    failover_priority = 3
    type              = "failover-only"
    weight            = 1
  }
  mac_override_enabled = false
  provider_capabilities = {
    download_kilobits_per_second = 300000
    upload_kilobits_per_second   = 150000
  }
  report_wan_event = false
}

resource "unifi_wan" "lte" {
  name               = "LTE Failover WAN"
  enabled            = true
  networkgroup       = "WAN_LTE_FAILOVER"
  setting_preference = "auto"
  type               = "static"
  vlan = {
    enabled = false
  }
  dslite = {
    remote_host_auto = false
  }
  interface_mtu_enabled = false
  # load_balance is left out: the controller holds failover_priority -1, which
  # the provider rejects in config (valid range 1-10); it is computed and kept.
  mac_override_enabled = false
  report_wan_event     = true
}
