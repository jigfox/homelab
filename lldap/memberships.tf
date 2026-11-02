# lldap_group_memberships is exclusive: it removes every member of the group
# that is not listed. So each managed group lists all its members; members
# that are not managed here (admin, tofu) must never belong to these groups.
resource "lldap_group_memberships" "this" {
  for_each = local.groups

  group_id = lldap_group.this[each.key].id
  user_ids = [for k, v in local.user_config : lldap_user.this[k].id if contains(v.groups, each.key)]
}
