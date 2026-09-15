#!/usr/bin/env bash
# Render every kustomization with placeholder values so the output can be
# schema-validated. Real values live in sops and are never needed here.
set -euo pipefail
out="${1:?usage: render.sh OUTDIR}"
mkdir -p "$out"
subst() {
  sed -E -e 's/\$\{GATEWAY_DOMAIN\}/example.com/g' \
         -e 's/\$\{ALERT_EMAIL_(FROM|TO)\}/noreply@example.com/g' \
         -e 's/\$\{(ETCD_IP_[0-9]|EVCC_MODBUS_HOST|CLUSTER_VIP|NODE[0-9]_IP|NAS_IP|DNS_[12])\}/10.0.0.1/g' \
         -e 's/\$\{LAN_PREFIX\}/10.0.0./g' \
         -e 's/\$\{LAN_SUBNET\}/10.0.0.0\/24/g' \
         -e 's/\$\{[A-Z_][A-Z0-9_]*\}/placeholder/g'
}
rc=0
while read -r d; do
  name="${d//\//_}"
  # drop sops-encrypted documents: flux decrypts them before apply, so their
  # ENC[...] values and sops: metadata are not meaningful to a schema check
  if kubectl kustomize "$d" 2>/tmp/err.txt | subst \
       | yq -P 'select(has("sops") | not)' - > "$out/$name.yaml"; then
    echo "  built   $d"
  else
    echo "  FAILED  $d"; sed 's/^/          /' /tmp/err.txt; rc=1
  fi
done < <(git ls-files 'kustomization.yaml' '*/kustomization.yaml' | xargs -n1 dirname | sort -u)
exit $rc
