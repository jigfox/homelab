# Firewall groups used by the WireGuard server rules (firewall_rules.tf).

resource "unifi_firewall_group" "wireguard_ports" {
  name    = "WireGuard Ports"
  type    = "port-group"
  members = ["51820"]
}

# Prefix of the WireGuard clients, from var.firewall_cidrs.
resource "unifi_firewall_group" "wireguard_home_v6" {
  name    = "WG Home"
  type    = "ipv6-address-group"
  members = [local.firewall_cidrs.wireguard_home_v6]
}
