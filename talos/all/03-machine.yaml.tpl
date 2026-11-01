apiVersion: v1alpha1
kind: ResolverConfig
nameservers:
  {{- range .Data.dns }}
  - address: {{ . }}
  {{- end }}
---
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  rotate-server-certificates: "true"
---
apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP:
  validSubnets:
    - {{ .Data.lanSubnet }}
labels:
  topology.kubernetes.io/region: home
  topology.kubernetes.io/zone: {{ .Node.Data.zone }}
