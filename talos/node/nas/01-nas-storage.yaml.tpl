# nas-only: the md RAID5 array and the kernel NFS server.
#
# Talos 1.14 can provision md arrays itself (RAIDArrayConfig) but only raid1,
# so the RAID5 is created once by `mise //talos:raid-create`. Talos then
# assembles it at boot (udev incremental assembly, md-name symlink
# /dev/disk/by-id/md-name-talos:nas-data) and mounts the xfs on it as
# /var/mnt/nas-data. The array name and homehost must match that symlink.
apiVersion: v1alpha1
kind: KernelModuleConfig
name: raid456
---
apiVersion: v1alpha1
kind: KernelModuleConfig
name: nfsd
---
apiVersion: v1alpha1
kind: ExistingVolumeConfig
name: nas-data
discovery:
  volumeSelector:
    match: volume.name == "xfs" && "/dev/disk/by-id/md-name-talos:nas-data" in disk.symlinks
---
# the kernel NFS server (NFSv4 only, so just 2049). Clients mount from the host
# network namespace (kubelet via csi-driver-nfs), so the node LAN is enough.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: nfs-ingress
portSelector:
  ports:
    - 2049
  protocol: tcp
ingress:
  - subnet: {{ .Data.lanSubnet }}
