# Import blocks for objects that already exist on the controller. Temporary:
# delete after the first approved apply. The Hichi read head is a known client
# (on the Default network until the reservation moves it to IoT).

import {
  to = unifi_client.this["tasmota-4"]
  id = nonsensitive(local.clients["tasmota-4"].mac)
}
