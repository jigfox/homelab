# http_url, ldap_url and password come from LLDAP_HTTP_URL, LLDAP_LDAP_URL and
# LLDAP_PASSWORD (Secret lldap-credentials, injected into the runner pod).
#
# The account is the dedicated lldap user `tofu` (member of lldap_admin), created
# by hand: it cannot be a resource of the module that logs in with it. Likewise
# the built-in `admin` user and the lldap_* groups are not managed here.
provider "lldap" {
  username = var.lldap_username
  base_dn  = var.base_dn
}
