# Input variables come from the Secret lldap-vars (see
# infrastructure/configs/lldap/vars.yaml). tofu-controller's varsFrom hands over
# every Secret key as a variable of that name whose value is the raw text as a
# *string*, so structured values are JSON text that the module decodes.

variable "lldap_username" {
  description = "lldap account the provider logs in with (the hand-made user tofu)."
  type        = string
}

variable "base_dn" {
  description = "LDAP base DN of the lldap instance."
  type        = string
  sensitive   = true
}

variable "users" {
  description = <<-EOT
    JSON object keyed by the user slugs of local.user_config (users.tf), each
    {username, email, display_name?, first_name?, last_name?}: the secret half
    of a user. The groups are public in users.tf.
  EOT
  type        = string
  sensitive   = true
}

locals {
  user_secrets = jsondecode(var.users)
  users = {
    for k, v in local.user_config : k => {
      username     = local.user_secrets[k].username
      email        = local.user_secrets[k].email
      display_name = try(local.user_secrets[k].display_name, null)
      first_name   = try(local.user_secrets[k].first_name, null)
      last_name    = try(local.user_secrets[k].last_name, null)
    }
  }
  user_keys = toset(keys(local.user_config))
}
