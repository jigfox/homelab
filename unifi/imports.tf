# Temporary: adopts what the UDM's migration to the zone-based firewall (Network
# 11.0.99) left on the controller under new IDs. Delete this file after the first
# approved apply.

locals {
  # controller IDs of the policies in local.firewall_policies
  policy_ids = {
    "external-external/public-gateway-https-v4" = "26e665e5-a816-4e73-9704-1631dcc93cea"
    "external-external/public-gateway-https-v6" = "691eec27-9a55-4efe-8446-edd86caed51f"
    "external-gateway/wireguard-server-v6"      = "d328f398-3d34-498c-a772-cee44abce8b2"
    "internal-external/established"             = "49c6a834-33cd-4b5c-8847-bebd2de12cf8"
    "internal-external/iot-dns"                 = "4a80b0e8-3ebe-4c91-b72f-ad366cf9542b"
    "internal-external/iot-drop"                = "7a398f15-2c26-4fce-a4ab-3ac815a50c9b"
    "internal-external/iot-internet"            = "da077c46-d651-4602-84a7-32fd5f1ad88f"
    "internal-external/iot-mqtt"                = "e79489ae-aade-4a44-8dba-3613e6212baf"
    "internal-external/iot-ntp"                 = "a63ebdeb-0bd8-4ea3-89f5-18a3e3018a80"
    "internal-external/iot-private"             = "fff56b9b-7a26-4a67-bf56-608eb5c0271d"
    "internal-external/lan-to-lb"               = "b35c4fa9-3585-4a8b-bfeb-cf8e4be9fbed"
    "internal-external/work-private"            = "274e3937-7e99-4ce7-9198-b405212fb917"
    "internal-gateway/iot-dhcp"                 = "2a919f7a-426c-4ab5-8c4d-bb1bb5fed768"
    "internal-gateway/iot-router-drop"          = "a26c539f-a5d3-44b8-8cff-663556506668"
    "internal-gateway/work-dhcp"                = "5bf99832-0ef2-45d7-b54e-27a7c5dbbc44"
    "internal-gateway/work-dns"                 = "ad91a3a2-2be8-4dd6-9267-8236c812ac2a"
    "internal-gateway/work-router-drop"         = "efa9e1da-9643-4ba0-a9b9-04b0513375ba"
    "internal-internal/established"             = "27e88f9e-5361-43f5-9dc9-05c7451898da"
    "internal-internal/into-work"               = "08bfdd13-7f51-415e-b6c5-cb0e5a3f98de"
    "internal-internal/iot-admins"              = "1d77cd04-4c86-495d-a25c-e630cc80b6f9"
    "internal-internal/iot-private"             = "3f9ee966-63eb-4ead-9b1e-1b4d7304847e"
    "internal-internal/work-private"            = "96e5f625-b200-4422-9c29-b11164a4a74b"
    "internal-vpn/established"                  = "79beb017-d915-42df-948b-7ed8db0b047a"
    "internal-vpn/iot-private"                  = "00fd704e-ed7a-48ab-8dd8-bbf223bbb449"
    "internal-vpn/work-private"                 = "a9185965-75ba-4a91-b113-ffeb231e3a1d"
    "vpn-external/wireguard-home-v6"            = "a4b67517-3353-443b-955a-21adae1e0e00"
  }
  # ... and of local.legacy_duplicates
  legacy_duplicate_ids = {
    "external-external/wireguard-home-v6"       = "ad31b6bb-c172-4bbd-9278-b0a48bb099a7"
    "external-hotspot/public-gateway-https-v4"  = "765a28cb-c8ac-46a5-9011-bf11c6e4fd5b"
    "external-hotspot/public-gateway-https-v6"  = "9564e078-77c0-499f-bb23-d604bf71c407"
    "external-internal/public-gateway-https-v4" = "665322ac-e4be-4db1-b815-401eb05a65de"
    "external-internal/public-gateway-https-v6" = "2a45f81f-87aa-4d09-b27e-29f3aff372c7"
    "external-vpn/public-gateway-https-v4"      = "10f4bf29-7665-4b09-956d-e3c3afbbd264"
    "external-vpn/public-gateway-https-v6"      = "70b77894-6f82-46c3-a135-9b0aa7a1d14b"
    "hotspot-external/wireguard-home-v6"        = "861009e0-0e83-4277-81b8-1c02a7cf93fe"
    "internal-external/wireguard-home-v6"       = "3f3bd692-b186-4001-9b8e-0225392cc818"
    "internal-hotspot/established"              = "c7a8dc95-1faa-4762-a268-b26684b6b903"
    "internal-hotspot/iot-dns"                  = "83834e25-c592-4b01-b3f2-305108ddd735"
    "internal-hotspot/iot-drop"                 = "a6dc7c0a-5d76-4a29-9e83-a168305e3a0e"
    "internal-hotspot/iot-internet"             = "d0f5da90-b629-41b6-ba5c-a4f6c4c36d9a"
    "internal-hotspot/iot-mqtt"                 = "0ccf390d-6c49-49ea-9978-e34f969a99eb"
    "internal-hotspot/iot-ntp"                  = "a48a055a-72aa-4f5b-b757-790cc53725de"
    "internal-hotspot/iot-private"              = "919cbea9-6a49-4989-bf29-305c9ae4965f"
    "internal-hotspot/work-private"             = "bbe0e496-f9dd-4bd6-aa1d-59539cfe0246"
    "internal-internal/iot-dns"                 = "d0bdd4b7-1c43-4c82-98c5-43346f5860c8"
    "internal-internal/iot-drop"                = "3005dd2b-209f-4e92-9e9f-0ecbe48c27d8"
    "internal-internal/iot-internet"            = "fb620b95-a885-43a4-8266-646e8d1723ed"
    "internal-internal/iot-mqtt"                = "db8d2ad5-e90a-4229-a6af-d44e848e0415"
    "internal-internal/iot-ntp"                 = "5732b366-5c19-4d57-a2e3-3945ba9dcfa0"
    "internal-vpn/iot-dns"                      = "17423fa9-47e6-47a8-a8c4-56bc367372f9"
    "internal-vpn/iot-drop"                     = "cb837974-1e36-4867-8b9f-f407aa985f24"
    "internal-vpn/iot-internet"                 = "535b0c6b-7fa2-4ac1-8547-04c735f04ba9"
    "internal-vpn/iot-mqtt"                     = "cd2bf5b0-48a8-458b-8755-5a3973c47148"
    "internal-vpn/iot-ntp"                      = "2a590b42-4afd-4bf7-a96f-65b6f9bc8b19"
  }
}

import {
  for_each = local.policy_ids
  to       = unifi_firewall_policy.this[each.key]
  id       = each.value
}

import {
  for_each = local.legacy_duplicate_ids
  to       = unifi_firewall_policy.legacy_duplicate[each.key]
  id       = each.value
}

# The DNAT and the peers got new IDs, but the old ones are still in the state:
# tofu skips an import whose address is already in the state, even when the
# refresh then finds the object gone. So they are imported under temporary
# addresses (..._imported) and the stale entries are dropped without destroying
# anything (the controller no longer has these objects). Rename back with a
# `moved` block when this file is deleted.
removed {
  from = unifi_nat.public_gateway_https
  lifecycle {
    destroy = false
  }
}

removed {
  from = unifi_wireguard_peer.this
  lifecycle {
    destroy = false
  }
}

# the DNAT got a new ID
import {
  to = unifi_nat.public_gateway_https_imported
  id = "b10ad0a9-c613-4821-8261-b3f630e3fb2e"
}

# the WireGuard peers got new IDs: <VPN server network id>:<peer id>
import {
  for_each = {
    "ipad-1"   = "ae612949-4ab9-480d-9ecd-3db08917e2ef"
    "ipad-2"   = "1b5487a5-c159-4292-a724-8c13eb1bb32f"
    "laptop-1" = "e0a095f5-0eb8-4116-9a65-01f70384d36e"
    "laptop-2" = "b73726c1-bd67-487d-9812-147f816e3e12"
    "phone-1"  = "c4a9d6c2-e277-4f4d-b052-ab7d8c76569c"
    "phone-2"  = "ca774f30-e57c-4ad9-914a-daca8a4651c2"
  }
  to = unifi_wireguard_peer.imported[each.key]
  id = "a76234dc-37d2-47fb-90e4-6df97f017967:${each.value}"
}
