# Firewall groups used by the WireGuard server rules (firewall_policies.tf).

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

# IoT network (firewall_policies.tf). Addresses from var.firewall_cidrs and
# var.clients.
resource "unifi_firewall_group" "private_v4" {
  name    = "RFC1918"
  type    = "address-group"
  members = ["10.0.0.0/8", "172.16.0.0/12", local.firewall_cidrs.private_192]
}

resource "unifi_firewall_group" "iot_dns" {
  name    = "IoT DNS"
  type    = "address-group"
  members = [local.firewall_cidrs.dns_a, local.firewall_cidrs.dns_b]
}

resource "unifi_firewall_group" "iot_mqtt" {
  name    = "IoT MQTT"
  type    = "address-group"
  members = [local.firewall_cidrs.mqtt]
}

# Devices allowed to open connections into the IoT network: the laptop and
# the WireGuard clients (tunnel subnet in network form).
resource "unifi_firewall_group" "iot_admins" {
  name = "IoT Admins"
  type = "address-group"
  members = [
    local.clients["laptop-1"].fixed_ip,
    cidrsubnet(local.wireguard.subnet, 0, 0),
  ]
}

# IoT devices that may reach the internet (everything else in IoT may not).
resource "unifi_firewall_group" "iot_internet" {
  name    = "IoT Internet"
  type    = "address-group"
  members = [local.clients["gardena"].fixed_ip]
}

resource "unifi_firewall_group" "dns_ports" {
  name    = "DNS"
  type    = "port-group"
  members = ["53"]
}

resource "unifi_firewall_group" "mqtt_ports" {
  name    = "MQTT TLS"
  type    = "port-group"
  members = ["8883"]
}

resource "unifi_firewall_group" "ntp_ports" {
  name    = "NTP"
  type    = "port-group"
  members = ["123"]
}

resource "unifi_firewall_group" "dhcp_ports" {
  name    = "DHCP"
  type    = "port-group"
  members = ["67"]
}

# Internet-facing Gateway "public" (infrastructure/base/gateway/public.yaml,
# unifi/port_forwards.tf). Addresses from var.firewall_cidrs.public_gateway_v4
# and public_gateway_v6.
resource "unifi_firewall_group" "public_gateway_v4" {
  name    = "Public Gateway IPv4"
  type    = "address-group"
  members = [local.firewall_cidrs.public_gateway_v4]
}

resource "unifi_firewall_group" "public_gateway_v6" {
  name    = "Public Gateway"
  type    = "ipv6-address-group"
  members = [local.firewall_cidrs.public_gateway_v6]
}

resource "unifi_firewall_group" "https_ports" {
  name    = "HTTPS"
  type    = "port-group"
  members = ["443"]
}
