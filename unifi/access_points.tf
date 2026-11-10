# Access points. Only ap-og is managed, for its radio settings. radio_table
# replaces the AP's whole radio list, so both radios are declared with every
# value the controller holds; a radio or attribute left out would be reset.
# Everything else on the AP (LED, outdoor mode, network config) stays as the
# controller has it.

resource "unifi_device" "ap_og" {
  name              = "ap-og"
  mgmt_network_id   = unifi_network.default.id
  forget_on_destroy = false # removing it from the module must not forget the AP

  radio_table = [
    {
      name                     = "ra0"
      radio                    = "ng"
      channel                  = "auto"
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
      channel                  = "auto"
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
