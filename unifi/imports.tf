# Temporary: adopts WANs and VPN clients that already exist on the controller
# (ids are opaque). Delete after the first approved apply.

import {
  to = unifi_wan.ftth
  id = "6ac4f984ac084ff785333b51"
}

import {
  to = unifi_wan.cable
  id = "67bdda118c4bf307104b2e35"
}

import {
  to = unifi_wan.internet_2
  id = "67bdda118c4bf307104b2e36"
}

import {
  to = unifi_wan.lte
  id = "67bddefa8c4bf307104b2f9e"
}

import {
  to = unifi_vpn_client.vpn_ams
  id = "69e09d25cbd3e0ba9cce6934"
}

import {
  to = unifi_vpn_client.vpn_fra
  id = "69e09d25cbd3e0ba9cce6937"
}
