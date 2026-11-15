terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    healthchecksio = {
      source  = "kristofferahl/healthchecksio"
      version = "2.3.0"
    }
  }
}
