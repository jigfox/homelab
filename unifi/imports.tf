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

# Clients are imported by MAC, taken from var.clients. OpenTofu rejects a
# sensitive import id, so the MAC shows in this plan's output (in-cluster only,
# never in git). Delete after the first approved apply.
import {
  for_each = local.client_keys
  to       = unifi_client.this[each.key]
  id       = nonsensitive(local.clients[each.key].mac)
}
