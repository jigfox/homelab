# Groups the apps authorize against (Authelia authorization policies). The
# built-in lldap_admin, lldap_password_manager and lldap_strict_readonly are
# not managed. Add a group here before a new Authelia client refers to it.
locals {
  groups = toset([
    "cluster-admin",
    "immich",
    "knx",
    "mealie",
    "mealie-admins",
    "paperless",
  ])
}

resource "lldap_group" "this" {
  for_each = local.groups

  display_name = each.key
}
