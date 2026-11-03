# shellcheck shell=bash
# Shared helpers for the node-by-node mise tasks (upgrade, reboot). Sourced, not
# executed; the task sets STATE (its resume file) and TASK (its name) first.
#
# A node is only touched while the cluster is healthy, and the next one only
# once every attached Longhorn volume is healthy again. Replica auto-balance is
# switched off meanwhile, otherwise Longhorn shuffles replicas after every
# reboot; the original value is kept in $STATE, so a failed run leaves it
# disabled and re-running resumes.

NODE_TIMEOUT=1800
LH=longhorn-system

# prints one line per problem, nothing when all attached volumes are healthy
# and no replica is rebuilding
volume_problems() {
  {
    kubectl -n "$LH" get volumes.longhorn.io -o json | jq -r '
      .items[] | select(.status.state == "attached" and .status.robustness != "healthy")
      | "volume \(.metadata.name): \(.status.robustness)"'
    kubectl -n "$LH" get engines.longhorn.io -o json | jq -r '
      .items[] | select((.status.rebuildStatus // {} | length) > 0
        or any((.status.replicaModeMap // {})[]; . == "WO"))
      | "volume \(.spec.volumeName): replica rebuilding"'
  } | sort -u
}

node_problems() {
  kubectl get nodes -o json | jq -r '
    .items[] | select(any(.status.conditions[]; .type == "Ready" and .status != "True"))
    | "node \(.metadata.name): not Ready"'
  kubectl -n "$LH" get nodes.longhorn.io -o json | jq -r '
    .items[] | select(any(.status.conditions[]?; .type == "Ready" and .status != "True"))
    | "longhorn node \(.metadata.name): not Ready"'
}

cluster_problems() {
  node_problems
  volume_problems
}

# wait_until <description> <command...>; the command succeeds when done
wait_until() {
  local what=$1
  shift
  local deadline=$((SECONDS + NODE_TIMEOUT))
  until "$@"; do
    if ((SECONDS > deadline)); then
      echo "timed out after $((NODE_TIMEOUT / 60))m waiting for: $what" >&2
      return 1
    fi
    sleep 10
  done
}

volumes_settled() {
  [[ -z "$(cluster_problems)" ]]
}

autobalance() {
  kubectl -n "$LH" get settings.longhorn.io replica-auto-balance -o jsonpath='{.value}'
}

set_autobalance() {
  kubectl -n "$LH" patch settings.longhorn.io replica-auto-balance --type merge \
    -p "{\"value\":\"$1\"}"
}

fail_hint() {
  echo "$1" >&2
  echo "unhealthy right now:" >&2
  cluster_problems | sed 's/^/  /' >&2 || true
  echo "replica-auto-balance stays disabled (original in $STATE);" >&2
  echo "fix the cluster, then re-run: mise //talos:$TASK" >&2
  exit 1
}

# fills the array `order`: workers first, then control planes, the nas last
node_order() {
  local nodes_yaml node
  nodes_yaml=$(sops -d topf.yaml)
  order=()
  while IFS= read -r node; do
    order+=("$node")
  done < <(
    yq -r '.nodes[] | select(.role == "worker") | .host' <<<"$nodes_yaml"
    yq -r '.nodes[] | select(.role != "worker" and .host != "nas") | .host' <<<"$nodes_yaml"
    yq -r '.nodes[] | select(.host == "nas") | .host' <<<"$nodes_yaml"
  )
}

# refuses to start on an unhealthy cluster, then saves the auto-balance value
# (unless resuming) and disables it
start_rollout() {
  local problems
  problems=$(cluster_problems)
  if [[ -n "$problems" ]]; then
    echo "cluster is not healthy, not starting:" >&2
    echo "  ${problems//$'\n'/$'\n'  }" >&2
    exit 1
  fi

  mkdir -p backup
  if [[ -f "$STATE" ]]; then
    echo "resuming, keeping the saved replica-auto-balance $(jq -r '.replicaAutoBalance' "$STATE")"
  else
    jq -n --arg v "$(autobalance)" '{replicaAutoBalance: $v}' >"$STATE"
  fi
  set_autobalance disabled
}

# etcd status, auto-balance restored, one descheduler run, pods per node
finish_rollout() {
  local endpoints job
  endpoints=$(yq '.contexts[.context].endpoints | join(",")' clusterconfig/talosconfig)
  talosctl -n "$endpoints" etcd status

  set_autobalance "$(jq -r '.replicaAutoBalance' "$STATE")"
  rm -f "$STATE"
  echo "replica-auto-balance restored to $(autobalance)"

  # kubernetes never moves running pods back, so rebalance once now
  if kubectl -n kube-system get cronjob descheduler >/dev/null 2>&1; then
    job="descheduler-$TASK-$(date +%s)"
    kubectl -n kube-system create job --from=cronjob/descheduler "$job"
    kubectl -n kube-system wait --for=condition=complete "job/$job" --timeout=10m
    wait_until "all Longhorn volumes healthy after the descheduler run" volumes_settled ||
      { cluster_problems >&2; exit 1; }
  else
    echo "warning: cronjob kube-system/descheduler not found, skipping rebalancing" >&2
  fi

  echo "running pods per node (without DaemonSets):"
  kubectl get pods -A -o json | jq -r '
    [.items[] | select(.status.phase == "Running"
      and (any(.metadata.ownerReferences[]?; .kind == "DaemonSet") | not))]
    | group_by(.spec.nodeName)[] | "  \(.[0].spec.nodeName): \(length)"'
}
