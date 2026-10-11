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
---
machine:
  registries:
    mirrors:
      hub.f9k.dev:
        endpoints:
          - http://127.0.0.1:30050/
    config:
      registry.registry.svc.cluster.local:
        tls:
          insecureSkipVerify: true
      127.0.0.1:
        tls:
          insecureSkipVerify: true
      ghcr.io:
        auth:
          username: jigfox
          password: {{ .Data.githubToken }}
