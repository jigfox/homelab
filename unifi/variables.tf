# Input variables come from the Secret unifi-vars (see
# infrastructure/configs/unifi/vars.yaml). tofu-controller's varsFrom hands over
# every Secret key as a variable of that name whose value is the raw text as a
# *string*, never a typed object. Structured values therefore arrive as JSON
# text and the module decodes them (see local.networks).

variable "networks" {
  description = <<-EOT
    JSON object keyed by network resource name (default, homelab, iot), each
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
    JSON object keyed by a neutral slug (node1, nas, phone-1, ...), each
    {mac, fixed_ip, name?, note?, network?}. One entry per client that carries
    configuration (DHCP reservation, note, network override). `network` is the
    name of a unifi_network resource in this module (default, homelab, iot).
    MAC and IP never appear in git; the slugs are the state addresses.
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
  # The whole variable is sensitive, but for_each keys may not be: only the
  # slugs are taken out with nonsensitive(); every value is read through
  # local.clients[each.key] and stays sensitive.
  clients = {
    for k, v in jsondecode(var.clients) : k => {
      mac      = v.mac
      fixed_ip = try(v.fixed_ip, null)
      name     = try(v.name, null)
      note     = try(v.note, null)
      network  = try(v.network, null)
    }
  }
  client_keys = nonsensitive(toset(keys(jsondecode(var.clients))))

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
    JSON object slug -> CIDR for the firewall objects: {wireguard_home_v6}, the
    IPv6 prefix of the WireGuard clients (firewall group, NAT source). Addresses
    never appear in git.
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
