# A Kubernetes cluster with kubeadm

**Any conformant Kubernetes cluster runs this stack.** What follows is the
procedure we use to build ours — a convention, not a requirement. For the
general, official instructions see
[Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/).

Already have a cluster? Skip this document and go to
[Part C of the README](../README.md#part-c--the-modelsphere-stack).
Only trying the stack out? [README step 4](../README.md#4-create-the-cluster-kubeadm)
has the smallest single-node `kubeadm init` that works. This document is the
production shape: three control planes, a real init config, and the join
commands.

Two things below follow from Cilium being the CNI, which is what this procedure
assumes and what `enabled.cilium` defaults to. They are constraints, not
preferences — but only on that CNI, so see the note under them if you bring
your own:

- The cluster must come up **without kube-proxy** (`--skip-phases=addon/kube-proxy`),
  because Cilium replaces it.
- The pod CIDR — `podSubnet` here, `--pod-network-cidr` in the one-liner — goes
  into **`cilium.podCIDR`** in the environment file as the same value, and must
  be unique across any clusters that will ever route to each other. Different
  things read the two: kubeadm's value becomes kube-controller-manager's
  `--cluster-cidr`, while `cilium.podCIDR` becomes
  `ipam.operator.clusterPoolIPv4PodCIDRList`, which is what the operator
  allocates from. Setting them apart leaves the cluster disagreeing with itself.

On another CNI, both invert: set `enabled.cilium: false`, leave kube-proxy in
place, and take the pod CIDR from that CNI's requirements. The rest of this
procedure is unchanged.

## What this procedure builds

- three stacked control planes, Cilium 1.20.0 as the CNI, no kube-proxy
- Kubernetes v1.36 (`setup_k8s.yaml:20`)
- the Cilium chart pulled from `helm.cilium.io` at `versions.cilium` — the
  vendored tree under `cni/cilium/` is reference only

Example values, used throughout below — replace with the new cluster's own:

| Setting | The example used below |
| --- | --- |
| cp-1 / cp-2 / cp-3 | `10.0.0.30` / `.31` / `.32` |
| `controlPlaneEndpoint` | `newcluster-control-plane.lan:6443` — a VIP or a 3-A-record name, never a single node IP |
| podSubnet | `10.244.0.0/16` — constrained, see above (`environments/default.yaml` uses `192.168.0.0/16`) |
| serviceSubnet | `10.96.0.0/12` — the default; overlapping another cluster is fine |

## 1. Prepare the nodes

First add the new `controlPlaneEndpoint` name, as a new line, to the file
`k8s_hosts_file` names in your inventory (`sys/hosts` in `inventory.ini`), and
leave the entries for other clusters alone. `setup-k8s-offline` copies that
file into every node's `/etc/hosts`, so do it before node prep, not after --
and if the file is missing, the task is skipped without a word.

Then run [README step 2](../README.md#2-node-prep-ansible) against the new
group -- `make setup-all LIMIT=<new group>`, plus `SETUP_DISK=1` if this
cluster wants the data disk. What the nodes must satisfy is in the README's
[prerequisites](../README.md#1-prerequisites).


## 2. Write the init config

On cp-1, `/root/kubeadm-init.yaml`. kubeadm v1.36 = `v1beta4`, where `extraArgs` is a **list of
`{name, value}`**, not a map:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.0.0.30        # this node's own IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.3        # keep in step with offline/versions.env
controlPlaneEndpoint: "newcluster-control-plane.lan:6443"

# Where the control-plane images come from. Leave it out on a cluster with a
# network -- the default is registry.k8s.io.
#
# ⚠️ An air-gapped cluster MUST set it, and this is the step where that is
#    decided. kube-apiserver, etcd, the scheduler, the controller-manager,
#    coredns and pause belong to no chart, so `registry:` in the environment
#    file does not reach them: helm never sees these images. Left at the
#    default on a site with no egress, `kubeadm init` hangs pulling
#    registry.k8s.io and the cluster never comes up -- with the same images
#    sitting in the local registry, pushed there by `make offline-load` a
#    step earlier.
#
#    ⚠️ Only under `registryMode: rewrite`. Under `mirror` this key must stay
#    commented out: the addresses are meant to stay upstream and the node
#    redirects them, so setting it points kubeadm at a registry the mirror does
#    not answer for. See docs/offline-install.md.
#
#    The value is the same address as `registry:` in environments/<cluster>.yaml
#    and REGISTRY in offline/site.env. pause is a fourth place, and belongs to
#    containerd rather than kubeadm -- `make offline-install-tools` stamps
#    it. See offline/README.md.
# imageRepository: <registry>       # e.g. 10.0.0.9:5000, or harbor.internal/infra

networking:
  # pod IPs are real on-the-wire addresses: must be unique across clusters that
  # will ever route to each other or cluster-mesh. Must match Cilium's
  # clusterPoolIPv4PodCIDRList.
  podSubnet: 10.244.0.0/16
  # ClusterIPs never leave the node (translated to a pod IP first), so overlapping
  # the other cluster is fine — keep the default.
  serviceSubnet: 10.96.0.0/12

apiServer:
  certSANs:
    - newcluster-control-plane.lan
    - 10.0.0.30
    - 10.0.0.31
    - 10.0.0.32
    - 127.0.0.1

# these three default to 127.0.0.1 and are unscrapable; cheap now, static pod
# restarts on all 3 nodes later
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: "http://0.0.0.0:2381"
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

```bash
kubeadm config validate --config /root/kubeadm-init.yaml
```

## 3. Init cp-1

```bash
kubeadm init --config /root/kubeadm-init.yaml \
  --upload-certs \
  --skip-phases=addon/kube-proxy

mkdir -p $HOME/.kube && cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
```

Save both join commands it prints. The `--certificate-key` expires in 2h; reissue with
`kubeadm init phase upload-certs --upload-certs`.

The cluster now has **no CNI and no kube-proxy** — the second on purpose,
because Cilium replaces it. The node stays `NotReady` and CoreDNS `Pending`
until the CNI arrives with the rest of the stack in
[README step 6](../README.md#6-install-the-stack). That is expected, not a
failure.

## 4. Give Cilium this cluster's values

There is no separate CNI step: cilium is installed by the same
`make helm-apply` as everything else, and that apply waits for it, so the nodes
go `Ready` during it. What belongs here is the half that comes out of the cluster
you just created — cilium's values are not a file you copy, they are rendered
from this cluster's entry in `environments/`, and three of them have to match
what `kubeadm init` was told.

```yaml
# environments/newcluster.yaml — overlay on environments/default.yaml
cilium:
  clusterName: newcluster                        # unique per cluster
  clusterId: 1
  k8sServiceHost: newcluster-control-plane.lan   # = controlPlaneEndpoint above,
                                                 #   required with kubeProxyReplacement
  podCIDR: 10.244.0.0/16                         # = the podSubnet above
  operatorReplicas: 2
  serviceMonitors: false                         # no Prometheus operator yet
```

Register the environment under `environments:` in `helmfile.yaml.gotmpl`, then
run [README steps 5 and 6](../README.md#5-cluster-prerequisites). Checks:

```bash
kubectl get nodes                                    # cp-1 → Ready
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```

Once kube-prometheus-stack is in, flip `cilium.serviceMonitors: true` and
re-apply.

## 5. Join the rest

Control planes, **one at a time**, waiting for `Ready` before the next (each join adds an etcd
member):

```bash
kubeadm join newcluster-control-plane.lan:6443 \
  --token <token> --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <key> \
  --cri-socket unix:///run/containerd/containerd.sock
```

Workers: same without `--control-plane --certificate-key`. Tokens last 24h —
`kubeadm token create --print-join-command`.

```bash
kubectl get nodes
kubectl -n kube-system exec etcd-<cp-1-host> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table                               # 3 members
```

