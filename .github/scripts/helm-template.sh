#!/usr/bin/env bash
# Render every HelmRelease against the chart version it pins. This is what
# catches a values schema break on a chart bump, or a HelmRelease pointing at
# the wrong chart entirely.
set -uo pipefail
subst() {
  sed -E -e 's/\$\{GATEWAY_DOMAIN\}/example.com/g' \
         -e 's/\$\{ALERT_EMAIL_(FROM|TO)\}/noreply@example.com/g' \
         -e 's/\$\{[A-Z_][A-Z0-9_]*\}/10.0.0.1/g'
}
rc=0
added=""
for f in $(grep -rl "kind: HelmRelease" apps infrastructure --include='*.yaml' 2>/dev/null | sort); do
  name=$(yq -P 'select(.kind=="HelmRelease") | .metadata.name' "$f" | head -1)
  chart=$(yq -P 'select(.kind=="HelmRelease") | .spec.chart.spec.chart' "$f" | head -1)
  ver=$(yq -P 'select(.kind=="HelmRelease") | .spec.chart.spec.version' "$f" | head -1)
  src=$(yq -P 'select(.kind=="HelmRelease") | .spec.chart.spec.sourceRef.name' "$f" | head -1)
  case "$chart" in ""|null) continue;; esac
  url=$(yq -P "select(.metadata.name == \"$src\") | .spec.url" infrastructure/sources/*.yaml 2>/dev/null | grep -v '^null$' | head -1)
  if [ -z "$url" ]; then
    echo "  FAIL $name: no HelmRepository named '$src' in infrastructure/sources"; rc=1; continue
  fi
  case " $added " in *" $src "*) ;; *) helm repo add "$src" "$url" >/dev/null 2>&1; added="$added $src";; esac
  yq -P 'select(.kind=="HelmRelease") | .spec.values' "$f" | subst > /tmp/vals.yaml
  if helm template "$name" "$src/$chart" --version "$ver" -f /tmp/vals.yaml >/dev/null 2>/tmp/helm.err; then
    echo "  ok   $name -> $chart $ver ($src)"
  else
    echo "  FAIL $name -> $chart $ver ($src)"; sed 's/^/        /' /tmp/helm.err | head -5; rc=1
  fi
done
exit $rc
