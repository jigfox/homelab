# Input variables come from the Secret unifi-vars (see
# infrastructure/configs/unifi/vars.yaml). None yet.

# tofu-controller turns every key of unifi-vars into a variable; sops cannot
# encrypt an empty stringData, so the Secret holds this until real values exist
variable "placeholder" {
  type    = string
  default = ""
}
