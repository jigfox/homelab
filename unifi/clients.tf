# Clients that carry configuration (DHCP reservation, name, note, network
# override). Everything identifying lives in var.clients (Secret unifi-vars).
# Clients without any configuration are not managed.

resource "unifi_client" "this" {
  for_each = local.client_keys

  mac      = local.clients[each.key].mac
  fixed_ip = local.clients[each.key].fixed_ip
  name     = local.clients[each.key].name
  note     = local.clients[each.key].note
  # network override: only when the entry names a network
  network_id = (
    local.clients[each.key].network == null ? null :
    { default = unifi_network.default.id, homelab = unifi_network.homelab.id, iot = unifi_network.iot.id }[local.clients[each.key].network]
  )
}
