# Input variables come from the Secret unifi-vars (see
# infrastructure/configs/unifi/vars.yaml). tofu-controller's varsFrom hands over
# every Secret key as a variable of that name whose value is the raw text as a
# *string*, never a typed object. Structured values therefore arrive as JSON
# text and the module decodes them (see local.networks).

variable "networks" {
  description = <<-EOT
    JSON object keyed by network resource name (default, homelab, iot), each
    {subnet, dhcp_start, dhcp_stop, domain_name?, dhcp_dns?, dhcp_v6_dns?}. Holds every
    address of the LANs so nothing sensitive is in git.
  EOT
  type        = string
  sensitive   = true
}

locals {
  networks = {
    for k, v in jsondecode(var.networks) : k => {
      subnet      = v.subnet
      dhcp_start  = v.dhcp_start
      dhcp_stop   = v.dhcp_stop
      domain_name = try(v.domain_name, null)
      dhcp_dns    = try(v.dhcp_dns, null)
      dhcp_v6_dns = try(v.dhcp_v6_dns, null)
    }
  }
}
