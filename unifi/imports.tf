# Temporary: adopt the UI-created Work network and the client already on it.
# Delete after the first approved apply.
import {
  to = unifi_network.work
  id = "6ae9ad36a8674d30d9184d5b"
}

import {
  to = unifi_client.this["laptop-2"]
  id = nonsensitive(local.clients["laptop-2"].mac)
}
