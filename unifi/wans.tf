# The four WAN uplinks. Structure in HCL; the PPPoE user name and the ISP display
# name of `cable` come from var.wans (Secret unifi-vars). The PPPoE password
# (`password_wo`) is not managed yet: it stays on the controller untouched.

resource "unifi_wan" "ftth" {
  name               = "FTTH"
  enabled            = true
  networkgroup       = "WAN3"
  setting_preference = "manual"
  type               = "pppoe"
  type_v6            = "dhcpv6"
  username           = local.wans.ftth.username
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

resource "unifi_wan" "internet_2" {
  name               = "Internet 2"
  enabled            = true
  networkgroup       = "WAN2"
  setting_preference = "auto"
  type               = "dhcp"
  type_v6            = "disabled"
  vlan = {
    enabled = false
  }
  dhcpv6 = {
    pd = {
      size_auto = false
    }
    wan_delegation_type = "none"
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
  interface_mtu_enabled = false
  load_balance = {
    failover_priority = 3
    type              = "failover-only"
    weight            = 1
  }
  mac_override_enabled = false
  report_wan_event     = false
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
