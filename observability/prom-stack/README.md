additional setup for kube-prometheus-stack
---

1. etcd, scheduler, controller listen on node IP instead of 127.0.0.1
2. no kube-proxy in this cluster — set `kubeProxy.enabled: false`

1. goes into the `kubeadm init` config on a new cluster:
[`docs/kubeadm-cluster-init.md`](../../docs/kubeadm-cluster-init.md).
