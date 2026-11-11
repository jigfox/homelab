# Custom zones for the IoT and Work networks. Created empty first, so they have
# no effect on traffic; the networks move in once their policies exist. Order:
# zones, policies while the zones are empty, move the networks, then delete the
# old IoT/Work policies in the Internal zone pairs.
locals {
  custom_zones = {
    iot  = "IoT"
    work = "Work"
  }
}

resource "unifi_firewall_zone" "this" {
  for_each    = local.custom_zones
  name        = each.value
  network_ids = []
}
