# Sourced by the unifi:* tasks. Runs tofu in unifi/ against the same state as
# the tofu-controller Terraform CR `unifi` (kubernetes backend, Secret
# tfstate-default-unifi in flux-system) with the provider credentials taken
# from the sops Secret, never written to disk.

# export UNIFI_* from the encrypted Secret into this process only
unifi_credentials() {
  local root
  root=$(git rev-parse --show-toplevel)
  while IFS=$'\t' read -r k v; do export "$k=$v"; done < <(
    sops -d --extract '["stringData"]' --output-type json "$root/infrastructure/configs/unifi/credentials.yaml" \
      | jq -r 'to_entries[] | [.key, .value] | @tsv')
}

# GET a controller API path (e.g. proxy/network/v2/api/site/default/bgp/config)
# as the provider's user; read-only, the session cookie lives in a temp file
# that is removed again
unifi_api_get() {
  local jar rc
  jar=$(mktemp)
  unifi_credentials
  jq -nc --arg u "$UNIFI_USERNAME" --arg p "$UNIFI_PASSWORD" '{username: $u, password: $p}' \
    | curl -sk -c "$jar" -o /dev/null -H 'Content-Type: application/json' --data @- "$UNIFI_API/api/auth/login"
  curl -sk -b "$jar" -f "$UNIFI_API/$1"
  rc=$?
  rm -f "$jar"
  return $rc
}

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
  unifi_credentials
  # module variables, exactly as tofu-controller's varsFrom passes them: every
  # Secret key is variable <key>, set to the raw value as a *string* (HCL
  # decodes structured values with jsondecode in the module)
  local vars key
  vars=$(sops -d --extract '["stringData"]' --output-type json "$root/infrastructure/configs/unifi/vars.yaml")
  while IFS= read -r key; do
    export "TF_VAR_$key=$(jq -r --arg k "$key" '.[$k]' <<<"$vars")"
  done < <(jq -r 'keys[]' <<<"$vars")
  cd "$dir"
  tofu init -input=false \
    -backend-config="secret_suffix=unifi" \
    -backend-config="namespace=flux-system" \
    -backend-config="config_path=$KUBECONFIG" >/dev/null
  tofu "$cmd" "$@"
}

# one key of the unifi-vars Secret, as the raw string
unifi_vars_get() {
  sops -d --extract "[\"stringData\"][\"$1\"]" "$(git rev-parse --show-toplevel)/infrastructure/configs/unifi/vars.yaml"
}

# set one key of the unifi-vars Secret from stdin (raw string, JSON-encoded
# here for sops); nothing touches the disk or the process list
unifi_vars_set() {
  jq -Rsc . | sops set --value-stdin "$(git rev-parse --show-toplevel)/infrastructure/configs/unifi/vars.yaml" "[\"stringData\"][\"$1\"]"
}
