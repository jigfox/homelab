# The switch (USL24P "sw"). Only ports with a port_override block are managed:
# the provider merges them by index into the switch's current overrides, the
# other ports keep whatever the controller holds (today: defaults, i.e. native
# Default, all VLANs tagged). Removing a block stops managing that port but does
# not reset it; set it back to the defaults here first. Of the other UniFi
# devices only ap-og is managed (access_points.tf); the UDM's own ports are not.

resource "unifi_device" "switch" {
  name              = "sw"
  mgmt_network_id   = unifi_network.default.id
  forget_on_destroy = false # removing it from the module must not forget the switch

  # Gardena gateway (clients.tf `gardena`): untagged IoT, no other VLANs
  port_override {
    index                 = 18
    name                  = "Port 18"
    native_networkconf_id = unifi_network.iot.id
    tagged_vlan_mgmt      = "block_all"
    forward               = "native"
  }
}
