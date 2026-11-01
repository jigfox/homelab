# Control-plane additions to all/06-firewall.yaml.tpl.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kubernetes-api-ingress
portSelector:
  ports:
    - 6443
  protocol: tcp
ingress:
  - subnet: 0.0.0.0/0
  - subnet: ::/0
---
# workers fetch their certificates from trustd
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: trustd-ingress
portSelector:
  ports:
    - 50001
  protocol: tcp
ingress:
  - subnet: {{ .Data.lanSubnet }}
---
# etcd client and peer traffic. Only the node LAN, not the pods: topf
# templates see only their own node, so listing the control planes here would
# duplicate topf.yaml, and etcd requires client certificates from the Talos
# CA on both ports anyway.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: etcd-ingress
portSelector:
  ports:
    - 2379-2380
  protocol: tcp
ingress:
  - subnet: {{ .Data.lanSubnet }}
---
# scraped by vmagent: etcd metrics, controller-manager, scheduler
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: control-plane-metrics-ingress
portSelector:
  ports:
    - 2381
    - 10257
    - 10259
  protocol: tcp
ingress:
  - subnet: {{ .Data.lanSubnet }}
  - subnet: 10.244.0.0/16
  - subnet: fd00:10:244::/48
