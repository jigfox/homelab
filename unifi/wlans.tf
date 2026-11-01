# The WLANs. SSIDs come from var.wlans, passphrases and the PPSK key from
# var.wlan_passphrases (both in Secret unifi-vars); security, bands and the
# rest are structure and live here.
# Passphrases are write-only (passphrase_wo): never in state, only sent when
# passphrase_wo_version changes. To rotate one, change it in unifi-vars and
# bump that WLAN's passphrase_wo_version. The PPSK key is a normal sensitive
# attribute (kept in the in-cluster state) and converges like any other.

data "unifi_client_qos_rate" "default" {
  name = "Default"
}

data "unifi_ap_group" "all" {
  name = "All APs"
}

data "unifi_ap_group" "devices" {
  name = "devices_ap_group"
}

data "unifi_radius_profile" "default" {
  name = "Default"
}

# Main WLAN: both bands, WPA2-PSK, one PPSK entry on the default network.
resource "unifi_wlan" "main" {
  name          = local.wlans.main.ssid
  security      = "wpapsk"
  network_id    = unifi_network.default.id
  user_group_id = data.unifi_client_qos_rate.default.id
  wlan_bands    = ["2g", "5g"]
  wlan_band     = "both"
  hide_ssid     = false
  l2_isolation  = false
  pmf_mode      = "disabled"
  proxy_arp     = true
  no2ghz_oui    = true

  bss_transition                 = true
  minrate_setting_preference     = "auto"
  minimum_data_rate_2g_kbps      = 1000
  minimum_data_rate_5g_kbps      = 6000
  private_preshared_keys_enabled = true
  private_preshared_keys = [{
    network_id = unifi_network.default.id
    password   = local.wlan_passphrases.main_ppsk
  }]

  passphrase_wo         = local.wlan_passphrases.main
  passphrase_wo_version = 1

  ap_group = {
    ids  = [data.unifi_ap_group.all.id]
    mode = "all"
  }
  wpa = {
    mode = "wpa2"
    enc  = "ccmp"
  }
  wpa3 = {
    support      = false
    transition   = false
    fast_roaming = false
    enhanced_192 = false
  }
  roaming_assistant_na = {
    enabled = false
    rssi    = -75
  }
}

# 2.4 GHz-only WLAN on the default network, limited to a custom AP group.
resource "unifi_wlan" "devices_2g" {
  name          = local.wlans.devices_2g.ssid
  security      = "wpapsk"
  network_id    = unifi_network.default.id
  user_group_id = data.unifi_client_qos_rate.default.id
  wlan_bands    = ["2g"]
  wlan_band     = "2g"
  hide_ssid     = false
  l2_isolation  = false
  pmf_mode      = "disabled"
  proxy_arp     = false
  no2ghz_oui    = true

  bss_transition             = true
  minrate_setting_preference = "auto"
  minimum_data_rate_2g_kbps  = 1000
  minimum_data_rate_5g_kbps  = 6000

  passphrase_wo         = local.wlan_passphrases.devices_2g
  passphrase_wo_version = 1

  ap_group = {
    ids  = [data.unifi_ap_group.devices.id]
    mode = "devices"
  }
  wpa = {
    mode = "wpa2"
    enc  = "ccmp"
  }
  wpa3 = {
    support      = false
    transition   = false
    fast_roaming = false
    enhanced_192 = false
  }
}

# 2.4 GHz-only WLAN on the IoT network.
resource "unifi_wlan" "iot" {
  name          = local.wlans.iot.ssid
  security      = "wpapsk"
  network_id    = unifi_network.iot.id
  user_group_id = data.unifi_client_qos_rate.default.id
  wlan_bands    = ["2g"]
  wlan_band     = "2g"
  hide_ssid     = false
  l2_isolation  = false
  pmf_mode      = "disabled"
  proxy_arp     = false
  no2ghz_oui    = false

  bss_transition             = false
  minrate_setting_preference = "auto"
  minimum_data_rate_2g_kbps  = 1000
  minimum_data_rate_5g_kbps  = 6000

  passphrase_wo         = local.wlan_passphrases.iot
  passphrase_wo_version = 1

  ap_group = {
    ids  = [data.unifi_ap_group.all.id]
    mode = "all"
  }
  wpa = {
    mode = "wpa2"
  }
  wpa3 = {
    support      = false
    transition   = false
    fast_roaming = false
    enhanced_192 = false
  }
}

# WPA2-Enterprise WLAN (RADIUS), both bands, default network.
resource "unifi_wlan" "eap" {
  name          = local.wlans.eap.ssid
  security      = "wpaeap"
  network_id    = unifi_network.default.id
  user_group_id = data.unifi_client_qos_rate.default.id
  wlan_bands    = ["2g", "5g"]
  wlan_band     = "both"
  hide_ssid     = false
  l2_isolation  = false
  pmf_mode      = "disabled"
  proxy_arp     = false
  no2ghz_oui    = false

  bss_transition             = false
  group_rekey                = 3600
  minrate_setting_preference = "manual"
  minimum_data_rate_2g_kbps  = 1000
  minimum_data_rate_5g_kbps  = 6000

  ap_group = {
    ids  = [data.unifi_ap_group.all.id]
    mode = "all"
  }
  radius = {
    profile_id = data.unifi_radius_profile.default.id
  }
  wpa = {
    mode = "wpa2"
    enc  = "ccmp"
  }
  wpa3 = {
    support      = false
    transition   = false
    fast_roaming = false
    enhanced_192 = false
  }
  roaming_assistant_na = {
    enabled = false
    rssi    = -75
  }
}
