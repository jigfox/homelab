# Import blocks for objects that already exist on the controller. Temporary:
# delete after the first approved apply. The Tasmota plugs are known clients
# (on the Default network until they join the IoT WLAN).

import {
  for_each = toset(["tasmota-1", "tasmota-2", "tasmota-3"])
  to       = unifi_client.this[each.key]
  id       = nonsensitive(local.clients[each.key].mac)
}
