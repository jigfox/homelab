terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    lldap = {
      source  = "tasansga/lldap"
      version = "0.4.5"
    }
  }
}
