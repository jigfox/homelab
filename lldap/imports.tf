# Temporary: adopts the existing lldap objects. Delete this file after the
# first approved apply. Group ids are the numeric lldap ids.
locals {
  import_group_ids = {
    cluster-admin = "6"
    immich        = "7"
    knx           = "9"
    mealie        = "4"
    mealie-admins = "5"
    paperless     = "8"
  }
}

import {
  for_each = local.import_group_ids
  to       = lldap_group.this[each.key]
  id       = each.value
}

import {
  for_each = local.import_group_ids
  to       = lldap_group_memberships.this[each.key]
  id       = each.value
}

# user id = username
import {
  for_each = local.users
  to       = lldap_user.this[each.key]
  id       = nonsensitive(each.value.username)
}
