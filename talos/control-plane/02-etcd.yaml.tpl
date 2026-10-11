cluster:
  etcd:
    advertisedSubnets:
      - {{ .Data.lanSubnet }}
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
