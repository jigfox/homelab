# WireGuard VPN clients. Tunnel addresses, peer endpoint, peer public key and the
# private key come from var.vpn_clients (Secret unifi-vars). The provider reads
# the private key back, so plain `private_key` (in state, sensitive) is used and
# imports without a write; the write-only variant would be sent on first apply.
# No preshared key is in use (preshared_key_enabled = false).

resource "unifi_vpn_client" "vpn_ams" {
  name          = "ifog_ams"
  enabled       = true
  default_route = false
  pull_dns      = false
  subnet        = local.vpn_clients.vpn_ams.subnet
  ipv6_subnet   = local.vpn_clients.vpn_ams.ipv6_subnet

  wireguard = {
    interface             = "wan"
    dns_servers           = local.vpn_clients.vpn_ams.dns_servers
    preshared_key_enabled = false
    private_key           = local.vpn_clients.vpn_ams.private_key
    peer = {
      ip         = local.vpn_clients.vpn_ams.peer_ip
      port       = local.vpn_clients.vpn_ams.peer_port
      public_key = local.vpn_clients.vpn_ams.peer_public_key
    }
  }
}

resource "unifi_vpn_client" "vpn_fra" {
  name          = "vultr_fra"
  enabled       = true
  default_route = false
  pull_dns      = false
  subnet        = local.vpn_clients.vpn_fra.subnet
  ipv6_subnet   = local.vpn_clients.vpn_fra.ipv6_subnet

  wireguard = {
    interface             = "wan"
    dns_servers           = local.vpn_clients.vpn_fra.dns_servers
    preshared_key_enabled = false
    private_key           = local.vpn_clients.vpn_fra.private_key
    peer = {
      ip         = local.vpn_clients.vpn_fra.peer_ip
      port       = local.vpn_clients.vpn_fra.peer_port
      public_key = local.vpn_clients.vpn_fra.peer_public_key
    }
  }
}
