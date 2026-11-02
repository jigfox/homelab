# Sourced by the <module>:approve tasks. Shows the pending plan of the Terraform
# CR <tf> (module in <tf>/, vars Secret <tf>-vars) and approves it on the
# cluster (-y skips the prompt).
tofu_approve() {
  local tf="$1" ns=flux-system pending root want have sha last answer
  shift
  # Approval goes to the cluster object, never to git: a commit is a new revision
  # and the controller would plan again under a new id (see CLAUDE.md).

  pending=$(kubectl -n "$ns" get terraform "$tf" -o jsonpath='{.status.plan.pending}')
  if [[ -z "$pending" ]]; then
    echo "No pending plan:"
    kubectl -n "$ns" get terraform "$tf" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
    exit 0
  fi

  # A plan computed before Flux updated the $tf-vars Secret uses the old values
  # (varsFrom is read at plan time). Compare the Secret with origin/main and
  # refuse while they differ; after Flux has caught up, ask for a fresh plan.
  root=$(git rev-parse --show-toplevel)
  git -C "$root" fetch -q origin main
  want=$(git -C "$root" show origin/main:infrastructure/configs/$tf/vars.yaml \
    | sops -d --input-type yaml --output-type json /dev/stdin | jq -S '.stringData' | shasum -a 256)
  have=$(kubectl -n "$ns" get secret $tf-vars -o json \
    | jq -S '.data | map_values(@base64d)' | shasum -a 256)
  if [[ "$want" != "$have" ]]; then
    echo "$tf-vars in the cluster differs from origin/main: Flux has not applied it yet." >&2
    echo "Run: flux reconcile kustomization infra-$tf --with-source" >&2
    echo "then request a fresh plan and approve again:" >&2
    echo "  kubectl -n $ns patch terraform $tf --subresource=status --type merge \\" >&2
    echo "    -p '{\"status\":{\"plan\":{\"pending\":\"\"},\"lastPlannedRevision\":\"\",\"lastAttemptedRevision\":\"\"}}'" >&2
    exit 1
  fi

  # the human-readable plan of exactly this run; addresses are sensitive and masked
  kubectl -n "$ns" get configmap "tfplan-default-$tf" -o jsonpath='{.data.tfplan}'
  echo
  echo "Pending: $pending"

  if [[ "${1:-}" != "-y" ]]; then
    if [[ ! -t 0 ]]; then
      echo "No terminal to ask on; rerun with -y to approve $pending." >&2
      exit 1
    fi
    read -r -p "Apply this plan? [y/N] " answer
    [[ "$answer" == [yY] ]] || { echo "Not approved."; exit 1; }
  fi

  kubectl -n "$ns" patch terraform "$tf" --type merge \
    -p "{\"spec\":{\"approvePlan\":\"$pending\"}}"
  kubectl -n "$ns" annotate terraform "$tf" --overwrite \
    "reconcile.fluxcd.io/requestedAt=$(date +%s)" >/dev/null

  # plan-main-<sha prefix> is applied once lastAppliedRevision is main@sha1:<sha>
  sha=${pending##*-}
  echo "Waiting for the apply ..."
  for _ in $(seq 1 60); do
    last=$(kubectl -n "$ns" get terraform "$tf" -o jsonpath='{.status.lastAppliedRevision}')
    [[ "${last##*:}" == "$sha"* ]] && break
    sleep 5
  done
  kubectl -n "$ns" get terraform "$tf" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
}
