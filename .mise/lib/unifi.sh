# Sourced by the unifi:* tasks. Runs tofu in unifi/ against the same state as
# the tofu-controller Terraform CR `unifi` (kubernetes backend, Secret
# tfstate-default-unifi in flux-system) with the provider credentials taken
# from the sops Secret, never written to disk.
unifi_tofu() {
  local root dir cmd="$1"
  shift
  root=$(git rev-parse --show-toplevel)
  dir="$root/unifi"
  # partial backend block, gitignored; the settings come from -backend-config
  cat > "$dir/backend_local.tf" <<'HCL'
terraform {
  backend "kubernetes" {}
}
HCL
  # export UNIFI_* from the encrypted Secret into this process only
  while IFS=$'\t' read -r k v; do export "$k=$v"; done < <(
    sops -d --extract '["stringData"]' --output-type json "$root/infrastructure/configs/unifi/credentials.yaml" \
      | jq -r 'to_entries[] | [.key, .value] | @tsv')
  cd "$dir"
  tofu init -input=false \
    -backend-config="secret_suffix=unifi" \
    -backend-config="namespace=flux-system" \
    -backend-config="config_path=$KUBECONFIG" >/dev/null
  tofu "$cmd" "$@"
}
