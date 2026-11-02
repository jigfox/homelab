# Import blocks for objects that already exist on the controller. Temporary:
# delete after the first approved apply. The Gardena gateway is a known client
# (on Default until its switch port moves to IoT).

import {
  to = unifi_client.this["gardena"]
  id = nonsensitive(local.clients["gardena"].mac)
}
