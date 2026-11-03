# Static local DNS records (var.dns_records) used to live here as
# unifi_dns_record.this. Its only entries, sso.${GATEWAY_DOMAIN} A and AAAA,
# moved to external-dns-udm, which adopted the existing records through its
# ownership TXTs: forget the resource without deleting anything on the UDM.
# Delete this block after the first approved apply. For a new static record,
# bring back the resource (see git history) and its entry in dns_records.
removed {
  from = unifi_dns_record.this
  lifecycle {
    destroy = false
  }
}
