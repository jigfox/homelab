machine:
  network:
    interfaces:
      - interface: end0
        dhcp: true
        vip:
          ip: {{ .Data.clusterVip }}
        vlans:
          - vlanId: 2
            dhcp: true
            dhcpOptions:
              routeMetric: 4096
      - interface: enp2s0
        dhcp: true
        vip:
          ip: {{ .Data.clusterVip }}
        vlans:
          - vlanId: 2
            dhcp: true
            dhcpOptions:
              routeMetric: 4096
