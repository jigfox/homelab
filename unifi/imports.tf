# One-shot: the controller imports the existing LANs on its first approved
# apply. Delete this file afterwards.
import {
  to = unifi_network.default
  id = "67bdda118c4bf307104b2e37"
}

import {
  to = unifi_network.homelab
  id = "67bf7d4c8666f21f4379e7d4"
}

import {
  to = unifi_network.iot
  id = "67c2b74a8666f21f437a9eb7"
}
