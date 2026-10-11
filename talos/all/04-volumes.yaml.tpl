apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: '{{ .Node.Data.dataDiskSelector }}'
  minSize: 50GB
  maxSize: 100GB
  grow: false
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn-data
provisioning:
  diskSelector:
    match: '{{ .Node.Data.dataDiskSelector }}'
  minSize: 800GB
  maxSize: 900GB
  grow: true
