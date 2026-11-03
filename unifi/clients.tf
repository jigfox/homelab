# Clients that carry configuration (DHCP reservation, name, note, network
# override). Clients without any configuration are not managed.
#
# The public part lives here so changes show in a plain diff: slug ->
# {name?, note?, network?}, where network is a unifi_network resource name
# (default, homelab, iot, work; for a wireless client a VLAN override). MAC and fixed
# IP are in var.clients (Secret unifi-vars) under the same slug. Slugs are
# public: keep them neutral (no names that identify people, no MACs).
locals {
  client_config = {
    node1     = {}
    node2     = {}
    node3     = {}
    node4     = {}
    nas       = { name = "nas" }
    pve       = { name = "pve" }
    tpi       = { name = "tpi" }
    ipmi      = { name = "ipmi" }
    inverter  = { name = "converter" }
    laptop-1  = { name = "mbp-wifi" }
    laptop-2  = { name = "work-laptop", network = "work" }
    phone-1   = {}
    client-1  = {}
    gardena   = { name = "Gardena Gateway", network = "iot" }
    tasmota-1 = { name = "pumpe", network = "iot" }
    tasmota-2 = { name = "router", network = "iot" }
    tasmota-3 = { network = "iot" }
  }
}

resource "unifi_client" "this" {
  for_each = local.client_keys

  mac      = local.clients[each.key].mac
  fixed_ip = local.clients[each.key].fixed_ip
  name     = local.clients[each.key].name
  note     = local.clients[each.key].note
  # network override: only when the entry names a network
  network_id = (
    local.clients[each.key].network == null ? null :
    { default = unifi_network.default.id, homelab = unifi_network.homelab.id, iot = unifi_network.iot.id, work = unifi_network.work.id }[local.clients[each.key].network]
  )
}

# A slug in unifi-vars without an entry above would silently be unmanaged.
check "client_slugs" {
  assert {
    condition     = length(setsubtract(nonsensitive(keys(jsondecode(var.clients))), keys(local.client_config))) == 0
    error_message = "var.clients has slugs missing from local.client_config in clients.tf."
  }
}
