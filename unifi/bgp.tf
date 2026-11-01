# BGP session to the Talos nodes (Cilium BGP control plane). The raw FRR config
# is kept as a template: structure in bgp.conf.tftpl, router ID, AS numbers and
# listen ranges from var.bgp (Secret unifi-vars). The provider never reads
# asn/router_id/peers back, so only the raw `config` mode is usable. A broken
# config drops the sessions and with them every LoadBalancer address.

resource "unifi_bgp" "this" {
  enabled          = true
  upload_file_name = "bgp.conf"
  description      = "BGP"
  config           = templatefile("${path.module}/bgp.conf.tftpl", local.bgp)
}
