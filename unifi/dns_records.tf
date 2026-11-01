# Static local DNS records. Names and values live in var.dns_records.

resource "unifi_dns_record" "this" {
  for_each = local.dns_record_keys

  name        = local.dns_records[each.key].name
  value       = local.dns_records[each.key].value
  record_type = local.dns_records[each.key].record_type
  ttl         = local.dns_records[each.key].ttl
  enabled     = local.dns_records[each.key].enabled
}
