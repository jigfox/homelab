# Shared helpers for the raid-* mise tasks. Sourced, not executed.
#
# Talos has no shell, so mdadm/mkfs/xfs_growfs run in a short-lived privileged
# pod pinned to the nas node (alpine + apk add mdadm xfsprogs). The pod sees the
# host's /dev and /var/mnt, so the array it creates is the host's array.

NODE=nas
ARRAY=nas-data                 # md name; Talos' homehost is "talos"
HOMEHOST=talos
ARRAY_DEV="/dev/disk/by-id/md-name-$HOMEHOST:$ARRAY"
MOUNT_NAME=nas-data            # ExistingVolumeConfig, mounted at /var/mnt/nas-data
MIN_SIZE=1500000000000         # refuse anything below 1.5 TB
POD=nas-raid-tool
POD_NS=kube-system             # PSA-exempt on Talos, exists before Flux has applied anything
POD_IMAGE=alpine:3.24.3
READY_TIMEOUT=300

nas_ip() {
  kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

# nas_resolve_disk <path>: validates one disk argument against what Talos
# knows about the node and prints its /dev/<name> path. Exits the script when
# the disk must not be touched.
nas_resolve_disk() {
  local arg="$1" ip disks vols dev size
  ip=$(nas_ip)
  disks=$(talosctl -n "$ip" get disks -o json 2>/dev/null | jq -s '.')
  vols=$(talosctl -n "$ip" get discoveredvolumes -o json 2>/dev/null | jq -s '.')
  local status
  status=$(talosctl -n "$ip" get volumestatus -o json 2>/dev/null | jq -s '.')

  dev=$(jq -r --arg a "$arg" '
    [.[] | select(.spec.dev_path == $a or any(.spec.symlinks[]?; . == $a))
         | .spec.dev_path] | unique | if length == 1 then .[0] else empty end' <<<"$disks")
  if [[ -z "$dev" ]]; then
    echo "refusing $arg: does not resolve to exactly one disk on $NODE" >&2
    return 1
  fi
  if [[ ! "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ && ! "$dev" =~ ^/dev/sd[a-z]+$ ]]; then
    echo "refusing $arg ($dev): not a whole nvme/sata disk" >&2
    return 1
  fi
  size=$(jq -r --arg d "$dev" '.[] | select(.spec.dev_path == $d) | .spec.size' <<<"$disks")
  if ((size < MIN_SIZE)); then
    echo "refusing $arg ($dev): $size bytes is below the $MIN_SIZE byte minimum" >&2
    return 1
  fi
  # any Talos volume (EPHEMERAL, STATE, u-*, ...) located on this disk
  local used
  used=$(jq -r --arg d "$dev" '
    .[] | select(.spec.parentLocation == $d or ((.spec.location // "") | startswith($d)))
    | .metadata.id' <<<"$status" | paste -sd, -)
  if [[ -n "$used" ]]; then
    echo "refusing $arg ($dev): backs Talos volume(s): $used" >&2
    return 1
  fi
  # any partition carrying a Talos partition label
  used=$(jq -r --arg d "$dev" '
    .[] | select(.spec.parent_dev_path == $d and .spec.partition_label != null)
    | .spec.partition_label' <<<"$vols" | paste -sd, -)
  if [[ -n "$used" ]]; then
    echo "refusing $arg ($dev): has labelled partition(s): $used" >&2
    return 1
  fi
  if jq -e --arg d "$dev" '.[] | select(.spec.dev_path == $d and .spec.system_disk == true)' <<<"$disks" >/dev/null; then
    echo "refusing $arg ($dev): system disk" >&2
    return 1
  fi
  echo "$dev"
}

# nas_describe_disk <dev>: one line for the plan (size, what is on it now)
nas_describe_disk() {
  local dev="$1" ip
  ip=$(nas_ip)
  talosctl -n "$ip" get disks -o json 2>/dev/null | jq -rs --arg d "$dev" '
    .[] | select(.spec.dev_path == $d)
    | "\($d)  \(.spec.size / 1e9 | floor) GB  \(.spec.model // "?")  \(.spec.serial // "?")"'
  talosctl -n "$ip" get discoveredvolumes -o json 2>/dev/null | jq -rs --arg d "$dev" '
    .[] | select(.spec.dev_path == $d or .spec.parent_dev_path == $d)
    | "    currently: \(.spec.dev_path) \(.spec.name)"'
}

nas_confirm() {
  [[ "${yes:-false}" == true ]] && return 0
  read -r -p "$1 [type 'yes'] " answer
  [[ "$answer" == yes ]]
}

nas_pod_start() {
  kubectl -n "$POD_NS" delete pod "$POD" --ignore-not-found --wait >/dev/null
  kubectl -n "$POD_NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  nodeName: $NODE
  restartPolicy: Never
  hostPID: true
  terminationGracePeriodSeconds: 5
  containers:
    - name: tool
      image: $POD_IMAGE
      command:
        - sh
        - -c
        - apk add --no-cache mdadm xfsprogs util-linux >/dev/null && touch /tmp/ready && sleep 86400
      securityContext:
        privileged: true
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {memory: 512Mi}
      volumeMounts:
        - {name: dev, mountPath: /dev}
        - {name: mnt, mountPath: /var/mnt, mountPropagation: HostToContainer}
  volumes:
    - {name: dev, hostPath: {path: /dev}}
    - {name: mnt, hostPath: {path: /var/mnt}}
YAML
  trap nas_pod_stop EXIT
  local i=0
  until kubectl -n "$POD_NS" exec "$POD" -- test -f /tmp/ready 2>/dev/null; do
    i=$((i + 2))
    if ((i >= READY_TIMEOUT)); then
      echo "tool pod not ready after ${READY_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
  done
}

nas_pod_stop() {
  kubectl -n "$POD_NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# nas_exec <sh script>: run in the tool pod
nas_exec() {
  kubectl -n "$POD_NS" exec "$POD" -- sh -ec "$1"
}

# nas_require_raid456: the raid456 module must be loaded (talos/node/nas patch applied)
nas_require_raid456() {
  local ip
  ip=$(nas_ip)
  if ! talosctl -n "$ip" read /proc/mdstat 2>/dev/null | grep -q 'raid[456]'; then
    echo "raid456 is not loaded on $NODE: apply the talos/node/nas patch (topf apply --mode=no-reboot) first" >&2
    return 1
  fi
}

# nas_wait_sync: print reshape/resync progress until the array is idle
nas_wait_sync() {
  local ip action line
  ip=$(nas_ip)
  while :; do
    action=$(talosctl -n "$ip" read "/sys/block/$(nas_array_kernel_name)/md/sync_action" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$action" || "$action" == idle ]] && break
    line=$(talosctl -n "$ip" read /proc/mdstat 2>/dev/null | grep -E 'recovery|reshape|resync' | head -1 || true)
    echo "$(date +%H:%M:%S) $action: ${line:-?}"
    sleep 60
  done
}

nas_array_kernel_name() {
  nas_exec "basename \"\$(readlink -f $ARRAY_DEV)\""
}

# nas_array_exists: the assembled array is known to Talos (md-name symlink present)
nas_array_exists() {
  talosctl -n "$(nas_ip)" get disks -o json 2>/dev/null |
    jq -se --arg l "$ARRAY_DEV" 'any(.[]; any(.spec.symlinks[]?; . == $l))' >/dev/null
}
