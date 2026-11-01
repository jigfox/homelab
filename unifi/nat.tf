# Masquerade for the WireGuard clients' IPv6 prefix (var.firewall_cidrs).

resource "unifi_nat" "wireguard_ipv6_masquerade" {
  description              = "WireGuard IPv6 Internet"
  type                     = "MASQUERADE"
  ip_version               = "IPV6"
  protocol                 = "all"
  setting_preference       = "manual"
  enabled                  = true
  exclude                  = false
  logging                  = false
  out_interface            = unifi_wan.cable.id
  pppoe_use_base_interface = false

  source_filter = {
    address        = local.firewall_cidrs.wireguard_home_v6
    filter_type    = "ADDRESS_AND_PORT"
    invert_address = false
    invert_port    = false
  }
}
