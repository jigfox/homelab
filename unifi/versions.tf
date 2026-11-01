terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "= 0.64.0"
    }
  }
}
