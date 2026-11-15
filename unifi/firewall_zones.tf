# Custom zones for the IoT and Work networks. Order of the migration: zones
# (created empty), their policies while the zones were empty, then the
# networks moved in (here), then the old IoT/Work policies in the Internal zone
# pairs go (they no longer match once the networks have left Internal).
locals {
  custom_zones = {
    iot  = { name = "IoT", network_ids = [unifi_network.iot.id] }
    work = { name = "Work", network_ids = [unifi_network.work.id] }
  }
}

resource "unifi_firewall_zone" "this" {
  for_each    = local.custom_zones
  name        = each.value.name
  network_ids = each.value.network_ids
}
