# Users and their groups. Public half: slug -> {groups}. The username, email and
# names are in var.users (Secret lldap-vars) under the same slug. Slugs are
# public: keep them neutral (no names that identify people).
#
# Passwords are never managed here: users set their own through lldap. The
# built-in `admin` and the hand-made `tofu` are not listed.
locals {
  user_config = {
    user-1 = { groups = ["cluster-admin", "immich", "knx", "mealie", "mealie-admins", "paperless"] }
  }
}

resource "lldap_user" "this" {
  for_each = local.user_keys

  username     = local.users[each.key].username
  email        = local.users[each.key].email
  display_name = local.users[each.key].display_name
  first_name   = local.users[each.key].first_name
  last_name    = local.users[each.key].last_name
}

# A slug in lldap-vars without an entry above would silently be unmanaged.
check "user_slugs" {
  assert {
    condition     = length(setsubtract(nonsensitive(keys(jsondecode(var.users))), keys(local.user_config))) == 0
    error_message = "var.users has slugs missing from local.user_config in users.tf."
  }
}
