# Temporary: adopts the WLANs that already exist on the controller. Delete after
# the first approved apply. The ids are opaque controller ids.

import {
  to = unifi_wlan.main
  id = "67bde1bc8c4bf307104b300a"
}

import {
  to = unifi_wlan.devices_2g
  id = "67bdf7738666f21f43799181"
}

import {
  to = unifi_wlan.iot
  id = "67c2b7f18666f21f437a9ef9"
}

import {
  to = unifi_wlan.eap
  id = "69ef51f4e296a1ebef76b79b"
}
