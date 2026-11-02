# Host ingress firewall: everything not allowed here is dropped. Talos always
# lets through loopback (also a node's traffic to its own IPs), established
# connections and rate-limited ICMP/ICMPv6. Traffic to pods and services is
# not affected: Cilium DNATs LoadBalancer/ClusterIP traffic in eBPF before it
# reaches the host (NetworkPolicies are for that).
#
# "cluster" below is the node LAN plus the pod CIDRs: pods (vmagent,
# metrics-server, hubble-relay) reach host ports from their pod IP, through the
# VXLAN tunnel when they run on another node.
#
# BGP (TCP 179) needs no rule: the UDM only listens (`bgp listen range` in
# unifi/bgp.conf.tftpl) and the Cilium agent on each node opens the session, so
# the router's packets belong to an established connection. If the FRR config
# ever lists the nodes as plain `neighbor`s, the UDM connects to the nodes
# itself and those connections are dropped here: allow 179 from the router
# first, or every LoadBalancer address (LAN DNS included) goes away.
#
# Control-plane-only ports are in control-plane/05-firewall.yaml.tpl. Roll out
# with `--mode=try` on one node first: a wrong rule cuts off apid.
apiVersion: v1alpha1
kind: NetworkDefaultActionConfig
ingress: block
---
# mTLS-authenticated; talosctl/topf from any admin machine
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: apid-ingress
portSelector:
  ports:
    - 50000
  protocol: tcp
ingress:
  - subnet: 0.0.0.0/0
  - subnet: ::/0
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kubelet-ingress
portSelector:
  ports:
    - 10250
  protocol: tcp
ingress:
  - subnet: {{ .Data.lanSubnet }}
  - subnet: 10.244.0.0/16
  - subnet: fd00:10:244::/48
---
# Cilium tunnel mode: pod traffic between nodes is VXLAN between node IPs
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: cilium-vxlan
portSelector:
  ports:
    - 8472
  protocol: udp
ingress:
  - subnet: {{ .Data.lanSubnet }}
---
# cilium-health (4240), hubble (4244), agent/operator/envoy metrics (9962-9964),
# node-exporter (9100)
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: node-agents-ingress
portSelector:
  ports:
    - 4240
    - 4244
    - 9100
    - 9962-9964
  protocol: tcp
ingress:
  - subnet: {{ .Data.lanSubnet }}
  # cilium-health probes the other nodes' IPv6 address as well (4240)
  - subnet: {{ .Data.lanSubnetV6 }}
  - subnet: 10.244.0.0/16
  - subnet: fd00:10:244::/48
---
# The Gateway's Envoy runs in the host network namespace: Cilium hands
# connections to the gateway's LoadBalancer IP to it via TPROXY, so they pass
# the host's input hook with their original port. Nothing else on the host
# listens on 80/443.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: gateway-ingress
portSelector:
  ports:
    - 80
    - 443
  protocol: tcp
ingress:
  - subnet: 0.0.0.0/0
  - subnet: ::/0
---
# the nodes get their addresses by DHCP (LAN and VLAN 2); offers to a client
# without a lease don't match an established connection
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: dhcp-client
portSelector:
  ports:
    - 68
  protocol: udp
ingress:
  - subnet: 0.0.0.0/0
