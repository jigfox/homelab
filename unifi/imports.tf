# Temporary: delete after the first approved apply that adopts these objects.
# The ids are opaque controller ids.

import {
  to = unifi_firewall_group.wireguard_ports
  id = "67da47508666f21f43803ebf"
}

import {
  to = unifi_firewall_group.wireguard_home_v6
  id = "69e935687d21380aa44e9c69"
}

import {
  to = unifi_firewall_rule.allow_wireguard_ports
  id = "67da47668666f21f43803ec1"
}

import {
  to = unifi_firewall_rule.allow_wireguard_home_v6
  id = "69e935d47d21380aa44e9caa"
}

import {
  to = unifi_nat.wireguard_ipv6_masquerade
  id = "69edf38ee296a1ebef765ff1"
}
