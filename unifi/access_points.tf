# Access points. ap-og and ap-eg are managed, for their radio settings;
# ap-ug (a U7 Lite) is not and stays on its own fixed channels. radio_table
# replaces the AP's whole radio list, so both radios are declared with every
# value the controller holds; a radio or attribute left out would be reset.
# Everything else on the APs (LED, outdoor mode, network config) stays as the
# controller has it.
#
# Channels are fixed, not auto: auto picks per AP without coordination and
# Radio AI is off, so two APs ended up co-channel (2.4 GHz channel 6) and on
# overlapping 5 GHz channels (80 MHz on 36-48 over a 40 MHz one on 44).
#   2.4 GHz (20 MHz): ap-og 1, ap-eg 6, ap-ug 13 (unmanaged)
#   5 GHz (40 MHz):   ap-og 44, ap-eg 36, ap-ug 128 (unmanaged)

resource "unifi_device" "ap_og" {
  name              = "ap-og"
  mgmt_network_id   = unifi_network.default.id
  forget_on_destroy = false # removing it from the module must not forget the AP

  radio_table = [
    {
      name                     = "ra0"
      radio                    = "ng"
      channel                  = "1"
      ht                       = 20
      tx_power_mode            = "auto"
      min_rssi_enabled         = false
      antenna_gain             = 3
      antenna_id               = -1
      vwire_enabled            = true
      dfs                      = false
      hard_noise_floor_enabled = false
      loadbalance_enabled      = false
      sens_level_enabled       = false
    },
    {
      # 40 instead of 80 MHz: a sturdier link for clients at the edge of
      # coverage (a work laptop at about -67 dBm), at the cost of peak speed
      name                     = "rai0"
      radio                    = "na"
      channel                  = "44"
      ht                       = 40
      tx_power_mode            = "auto"
      min_rssi_enabled         = false
      antenna_gain             = 3
      antenna_id               = -1
      vwire_enabled            = true
      dfs                      = false
      hard_noise_floor_enabled = false
      loadbalance_enabled      = false
      sens_level_enabled       = false
    },
  ]
}

resource "unifi_device" "ap_eg" {
  name              = "ap-eg"
  mgmt_network_id   = unifi_network.default.id
  forget_on_destroy = false # removing it from the module must not forget the AP

  radio_table = [
    {
      name                     = "ra0"
      radio                    = "ng"
      channel                  = "6"
      ht                       = 20
      tx_power_mode            = "auto"
      min_rssi_enabled         = false
      antenna_gain             = 3
      antenna_id               = -1
      vwire_enabled            = true
      dfs                      = false
      hard_noise_floor_enabled = false
      loadbalance_enabled      = false
      sens_level_enabled       = false
    },
    {
      # 40 instead of 80 MHz, like ap-og: a sturdier link at the edge of
      # coverage, and 36-40 does not overlap ap-og's 44-48
      name                     = "rai0"
      radio                    = "na"
      channel                  = "36"
      ht                       = 40
      tx_power_mode            = "auto"
      min_rssi_enabled         = false
      antenna_gain             = 3
      antenna_id               = -1
      vwire_enabled            = true
      dfs                      = false
      hard_noise_floor_enabled = false
      loadbalance_enabled      = false
      sens_level_enabled       = false
    },
  ]
}
