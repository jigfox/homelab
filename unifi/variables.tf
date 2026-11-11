# Input variables come from the Secret unifi-vars (see
# infrastructure/configs/unifi/vars.yaml). tofu-controller's varsFrom hands over
# every Secret key as a variable of that name whose value is the raw text as a
# *string*, never a typed object. Structured values therefore arrive as JSON
# text and the module decodes them (see local.networks).

variable "networks" {
  description = <<-EOT
    JSON object keyed by network resource name (default, homelab, iot, work), each
    {subnet, dhcp_start, dhcp_stop, domain_name?, dhcp_dns?, dhcp_v6_dns?}. Holds every
    address of the LANs so nothing sensitive is in git.
  EOT
  type        = string
  sensitive   = true
}

locals {
  networks = {
    for k, v in jsondecode(var.networks) : k => {
      subnet      = v.subnet
      dhcp_start  = v.dhcp_start
      dhcp_stop   = v.dhcp_stop
      domain_name = try(v.domain_name, null)
      dhcp_dns    = try(v.dhcp_dns, null)
      dhcp_v6_dns = try(v.dhcp_v6_dns, null)
    }
  }
}

variable "clients" {
  description = <<-EOT
    JSON object keyed by the client slugs of local.client_config (clients.tf),
    each {mac, fixed_ip?}: the secret half of a client. Name, note and network
    are public in clients.tf.
  EOT
  type        = string
  sensitive   = true
}

variable "dns_records" {
  description = <<-EOT
    JSON object keyed by a neutral slug, each {name, value, record_type?, ttl?,
    enabled?} for a static local DNS record (unifi_dns_record).
  EOT
  type        = string
  sensitive   = true
}

locals {
  # The slugs (for_each keys) come from the public local.client_config; MAC
  # and fixed IP from the sensitive var.clients, and stay sensitive.
  client_secrets = jsondecode(var.clients)
  clients = {
    for k, v in local.client_config : k => {
      mac      = local.client_secrets[k].mac
      fixed_ip = try(local.client_secrets[k].fixed_ip, null)
      name     = try(v.name, null)
      note     = try(v.note, null)
      network  = try(v.network, null)
    }
  }
  client_keys = toset(keys(local.client_config))

  dns_records = {
    for k, v in jsondecode(var.dns_records) : k => {
      name        = v.name
      value       = v.value
      record_type = try(v.record_type, "A")
      ttl         = try(v.ttl, null)
      enabled     = try(v.enabled, true)
    }
  }
  dns_record_keys = nonsensitive(toset(keys(jsondecode(var.dns_records))))
}

variable "wlans" {
  description = <<-EOT
    JSON object keyed by WLAN resource name (main, devices_2g, iot, eap), each
    {ssid}. The SSIDs never appear in git.
  EOT
  type        = string
  sensitive   = true
}

variable "wlan_passphrases" {
  description = <<-EOT
    JSON object WLAN resource name -> passphrase (main, devices_2g, iot), plus
    main_ppsk for the PPSK key of main. Sent write-only, see wlans.tf.
  EOT
  type        = string
  sensitive   = true
}

locals {
  wlans = {
    for k, v in jsondecode(var.wlans) : k => {
      ssid = v.ssid
    }
  }
  wlan_passphrases = jsondecode(var.wlan_passphrases)
}

variable "firewall_cidrs" {
  description = <<-EOT
    JSON object slug -> CIDR for the firewall objects: wireguard_home_v6, the
    IPv6 prefix of the WireGuard clients (server subnet_ipv6, firewall group): a
    GUA /64 of the fiber prefix (subnet id 77), so no NAT66; dns_a, dns_b and
    mqtt, the LoadBalancer addresses of Technitium and mosquitto-lan the IoT
    network may reach (plain addresses: the controller rejects /32 members); private_192, the private /16 the IoT rules block (the
    other RFC 1918 ranges are in HCL); public_gateway_v4 (plain address) and
    public_gateway_v6 (a /64 of the fiber prefix), the LoadBalancer addresses of the
    internet-facing Gateway `public`; lb_pool_v4 and lb_pool_v6, the internal LoadBalancer
    pools (the policy internal-external/lan-to-lb). Addresses never appear in git.
  EOT
  type        = string
  sensitive   = true
}

locals {
  firewall_cidrs = jsondecode(var.firewall_cidrs)
}

variable "wans" {
  description = <<-EOT
    JSON object keyed by WAN resource name: {ftth: {username, password}, cable:
    {name}}. The PPPoE credentials of ftth and the ISP display name of cable
    never appear in git.
  EOT
  type        = string
  sensitive   = true
}

variable "vpn_clients" {
  description = <<-EOT
    JSON object keyed by VPN client resource name (vpn_ams, vpn_fra), each
    {subnet, ipv6_subnet, dns_servers, peer_ip, peer_port, peer_public_key,
    private_key}. Tunnel addresses, peer endpoint and both keys.
  EOT
  type        = string
  sensitive   = true
}

locals {
  wans        = jsondecode(var.wans)
  vpn_clients = jsondecode(var.vpn_clients)
}

variable "bgp" {
  description = <<-EOT
    JSON object with the values of bgp.conf.tftpl: {router_id, local_asn,
    peer_asn_v4, peer_asn_v6, listen_v4, listen_v6}. The router's own AS and
    router ID, the AS numbers the Talos nodes peer with and the two ranges the
    router accepts dynamic neighbors from. None of it appears in git.
  EOT
  type        = string
  sensitive   = true
}

locals {
  bgp = jsondecode(var.bgp)
}

variable "wireguard" {
  description = <<-EOT
    JSON object {subnet, dns_servers}: the WireGuard road-warrior server's
    tunnel network in gateway form (first address plus mask) and the resolvers
    it pushes to clients. Addresses never appear in git.
  EOT
  type        = string
  sensitive   = true
}

variable "wireguard_peers" {
  description = <<-EOT
    JSON object keyed by a neutral device slug (laptop-1, phone-1, ...), each
    {interface_ip, interface_ipv6, public_key, private_key}. Maintained by
    `mise run unifi:wg-add-peer`; private_key is only there for
    `unifi:wg-profile` and unused by this module.
  EOT
  type        = string
  sensitive   = true
}

variable "ddns" {
  description = <<-EOT
    JSON object {zone, host_name}: the Cloudflare zone and the host name of the
    WireGuard endpoint (A = FTTH IPv4, AAAA = FTTH IPv6, both fixed and set
    once by hand at Cloudflare). Read by unifi:wg-profile, see wireguard.tf.
  EOT
  type        = string
  sensitive   = true
}

locals {
  wireguard = jsondecode(var.wireguard)
  ddns      = jsondecode(var.ddns)

  wireguard_peers     = jsondecode(var.wireguard_peers)
  wireguard_peer_keys = nonsensitive(toset(keys(jsondecode(var.wireguard_peers))))
}
