# Adding an Ascend NPU node

How to join a node that is **not** an Ubuntu/amd64/NVIDIA box — an Ascend NPU
host, aarch64, vendor OS — to one of our kubeadm clusters. The Ubuntu path
(`setup_k8s.yaml`, `network_accesslator.yaml`, `nvidia_audit.yaml`) assumes apt
and the NVIDIA operators; these nodes come with a vendor OS, a vendor driver and
a vendor container-runtime hook that we keep as they are.

**Read [the node prerequisites](../README.md#1-prerequisites) first.** The
kernel one (5.10+) is the one that actually stops nodes: an older vendor kernel
has to be replaced or reinstalled before anything here applies, and that is a
host-lifecycle job outside this repo.

There is no separate tooling for this. Node prep is the playbook every node
runs; the rest is kubeadm and kubectl, spelled out below so the reasons travel
with the commands. [`ascend/`](../ascend) holds only what is genuinely vendor
specific: the MindCluster chart, its values, and a smoke pod.

| Step | How | Runs on | Mutates |
|---|---|---|---|
| 0. Gate: will cilium start on this kernel? | probe the eBPF pairs (below) | node | no |
| 1. Leave the old cluster | `kubeadm reset` + cleanup (below) | node | yes |
| 2. Prep node | `setup_k8s.yaml` (Ansible, `k8s_install_method=binary`) | control machine | yes |
| 3. Join | `kubeadm join --config` (below) | node | yes |
| 4. Label the node, then the device plugin | `kubectl label`, then helmfile | cluster | yes |
| 5. Verify | `kubectl` + the smoke pod (below) | cluster | no |

Worked example throughout: one **Atlas 800T A2** (8× Ascend 910B3, Kylin V10,
kernel 4.19.90, aarch64), called `ascend-1` below, joining a cluster running
k8s v1.36.3, Cilium 1.20 and containerd 2.x on its other nodes.

---

## 0. Gate: kernel vs. Cilium — check this first

Cilium 1.20 refuses to start unless the kernel passes `CheckRequirements()`
(`pkg/datapath/linux/requirements.go`). It is a hard gate: there is no config
flag, `CiliumNodeConfig` or per-node override that skips it. Upstream this means
**kernel 5.10+**.

Vendor kernels make this easy to misjudge. Kylin's 4.19 backports most of the
eBPF you would check for — BTF, bounded loops, large programs, `fib_lookup`,
`redirect_neigh` all probe fine — so "the kernel looks recent enough" is not
evidence. Only the exact (program type, helper) pairs Cilium asks for are. Probe
them with the bpftool from the cilium image itself, so the answer comes from the
same library version the agent will use:

```bash
# on the candidate node, read-only
docker run --rm --privileged --net host quay.io/cilium/cilium:v1.20.0 \
    bpftool feature probe kernel > /tmp/probe.txt
# containerd-only hosts:
#   ctr -n k8s.io run --rm --privileged --net-host quay.io/cilium/cilium:v1.20.0 \
#       probe bpftool feature probe kernel > /tmp/probe.txt

# then, for each pair below, check it is listed under its program type:
awk '/^eBPF helpers supported for program type/{pt=$NF} pt=="sched_cls:"' /tmp/probe.txt | grep bpf_redirect_peer
```

The pairs `CheckRequirements()` checks, with the kernel that first shipped each:

| program type | helper | since |
|---|---|---|
| sched_cls | `bpf_skb_change_tail` | 4.9 |
| cgroup_sock_addr | `bpf_get_socket_cookie` | 4.12 |
| cgroup_sock_addr | `bpf_get_current_cgroup_id` | 4.18 |
| sched_cls | `bpf_fib_lookup` | 4.18 |
| cgroup_sock, cgroup_sock_addr, sched_cls, xdp | `bpf_jiffies64` | 5.6 |
| cgroup_sock, cgroup_sock_addr | `bpf_get_netns_cookie` | 5.7 |
| sched_cls | `bpf_sk_assign` | 5.7 |
| cgroup_sock_addr | `bpf_get_cgroup_classid` | 5.7 |
| cgroup_sock_addr | `bpf_perf_event_output` | 5.7 |
| sched_cls | `bpf_csum_level` | 5.8 |
| sched_cls | `bpf_skb_change_head` | 5.8 |
| sched_cls | `bpf_redirect_neigh` | 5.10 |
| sched_cls | `bpf_redirect_peer` | 5.10 |

plus `Large program size limit is available` in the same output (5.2).

An empty probe output is **not** a pass — it means the probe did not run, and
the honest reading is "unknown", which here has to be treated as a fail.

On `ascend-1` (Kylin V10 4.19.90-52) six pairs were missing —
`bpf_get_current_cgroup_id` in cgroup_sock_addr, `bpf_get_netns_cookie` in both
cgroup types, `bpf_sk_assign`, `bpf_csum_level` and `bpf_redirect_peer` in
sched_cls. Every generic eBPF probe had passed, the node joined fine, and then
cilium-agent crash-looped. A regular cluster node (Ubuntu 5.15) has all of them,
which is the control worth running alongside.

When a pair is missing, stop: the node needs a newer kernel first. On `ascend-1` the
4.19 Kylin kernel was replaced in place with openEuler 22.03 SP4's 5.10 (the
userspace, the Ascend driver and the data on the disks stayed), after which the
same script passes and step 1 below is where the cluster work starts.

Other things that are **not** blockers, verified on the same node:

| Concern | Outcome |
|---|---|
| cgroup v1 (kubelet ≥ 1.35 refuses by default) | works with `failCgroupV1: false`, patched in via `JoinConfiguration.patches` (step 3); kubelet only warns |
| containerd 1.7 (cluster runs 2.x) | works on 1.36; kubeadm warns that 1.7 lacks the CRI `RuntimeConfig` method and that the fallback goes away in **1.37** — upgrade containerd before the cluster does |
| aarch64 | cilium, cilium-envoy, node-problem-detector, node-exporter images are multi-arch |
| NVIDIA DaemonSets | gated by `nvidia.com/gpu.deploy.*` labels and `pci-15b3` (Mellanox); Huawei NICs (`19e5`) match neither, nothing lands |

---

## 1. Leave the old cluster

Only if the machine comes from one. `kubeadm reset` **against the CRI socket it
actually used** — KubeKey/KubeSphere nodes run cri-dockerd, and resetting the
containerd socket instead leaves every old pod running:

```bash
kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock   # or containerd.sock
```

> ⚠️ **Unmount before anything deletes `/var/lib/kubelet`.** `k3s-uninstall.sh`
> runs `rm -rf /var/lib/kubelet`; with a JuiceFS (or any network) CSI volume still
> mounted under it, that `rm` reaches through the mount and deletes the data on
> the remote filesystem. Check first, and do not continue until it is empty:
>
> ```bash
> mount | grep /var/lib/kubelet
> ```

Then the leftovers, in this order:

```bash
systemctl disable --now kubelet cri-dockerd k3s 2>/dev/null
ip link del tunl0 2>/dev/null; ip link del cali+ 2>/dev/null   # calico
umount /run/calico/cgroup 2>/dev/null
rm -rf /etc/cni/net.d/* /var/lib/cni /opt/cni/bin/calico*
```

> ⚠️ **Do not clean iptables with `iptables-save | grep -v ... | iptables-restore`.**
> That is a whole-table rewrite, not a delete: filtering by keyword leaves chain
> definitions and references out of step, and a restore that fails midway can take
> the management path down with it. Measured once here: a node lost both ping
> and SSH and had to be power-cycled out of band. `kubeadm reset`
> removes its own rules; deleting `/etc/cni/net.d/*` and the interfaces is enough
> for the CNI ones.

Keep: docker and whatever it runs outside Kubernetes, data mounts outside
kubelet's tree, the vendor driver and runtime.

The old cluster's API server still lists the node as `NotReady`; whoever owns
that cluster has to `kubectl delete node` it.

## 2. Prep the node

The same Ansible play every other node goes through — `setup_k8s.yaml` — with
the install method switched over. There is no separate script for this: node
prep had one implementation already, and a second one in bash would have drifted
from it the first time someone fixed a containerd setting in only one place.

Ansible needs a Python on the target that ansible-core supports — 3.8 or newer
for ansible-core 2.18. This is where a vendor OS bites: Kylin V10 ships 3.7.9 and
its repo has nothing newer, while CANN and `npu-smi` are built against that very
interpreter, so replacing it is out of the question. Install a self-contained one
next to it and point Ansible at that; nothing else on the host sees it.

```bash
# on the node, once -- chicken-and-egg: ansible cannot install what it needs to run
VER=3.11.16 TAG=20260901
curl -fsSL \
  "https://github.com/astral-sh/python-build-standalone/releases/download/$TAG/cpython-$VER+$TAG-aarch64-unknown-linux-gnu-install_only.tar.gz" \
  | tar -xz -C /opt/ansible-python --strip-components=1   # mkdir -p it first
/opt/ansible-python/bin/python3 -V
```

Removing `/opt/ansible-python` reverts it completely. An Ubuntu node needs none
of this; its system python is already new enough.

Put the node in an inventory. [`inventory-ascend.ini.example`](../inventory-ascend.ini.example)
is the shape, with every variable that differs from an Ubuntu node and why it is
there; copy it and fill in the host.

Do not skip `http_proxy` there if your nodes need one: github is not reachable
directly from ours, and dl.k8s.io is — so without it kubeadm, kubelet and
kubectl install fine and only the crictl download times out, which reads like a
flaky network rather than a missing setting.

Then, against whichever inventory holds it:

```bash
ansible-playbook -i <inventory> setup_k8s.yaml -l ascend910b-207 --tags online,offline
ansible-playbook -i <inventory> network_accesslator.yaml -l ascend910b-207   # certs.d mirrors
```

What the `binary` path does differently, and nothing else does:

- `kubeadm`/`kubelet`/`kubectl` from `dl.k8s.io` into `/usr/local/bin` (any distro,
  any arch — `k8s_arch` comes from `ansible_architecture`), crictl from GitHub,
  and the kubelet unit + `10-kubeadm.conf` the deb would have provided. Any other
  drop-in is removed: KubeKey leaves `--hostname-override` in one, which silently
  overrides what `kubeadm join` writes.
- containerd's `sandbox_image` set from `kubeadm config images list` (the vendor
  host's built-in pause is usually older than the cluster's).
- `k8s_accel_runtime=ascend` registers `ascend-docker-runtime` as a runc.v2
  runtime and makes it `default_runtime_name`.

Everything else — swap, modules, sysctl, `/etc/hosts`, `SystemdCgroup`, the 20m
pull timeout, `certs.d` — is the shared path, unchanged from the Ubuntu nodes.

> The containerd config is regenerated from `containerd config default` on every
> run, which is deliberate here: Ascend's installer had pointed runc at the
> removed v1 shim (`io.containerd.runtime.v1.linux`), which containerd 2.x will
> not start with. Patching the vendor's file would have kept that.

## 3. Join

Not the bare `kubeadm join` line from `kubeadm-cluster-init.md` — an older host
needs kubelet overrides, and they have to be in place *during* the join. Get a
token on the control plane (`kubeadm token create --ttl 1h --print-join-command`),
then on the node:

```bash
mkdir -p /etc/kubernetes/join-patches
cat > /etc/kubernetes/join-patches/kubeletconfiguration+strategic.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failCgroupV1: false                 # only on a cgroup v1 host
resolvConf: /etc/resolv.conf        # only without systemd-resolved
EOF

cat > /etc/kubernetes/join.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "<cp-endpoint:6443>"
    token: "<token>"
    caCertHashes: ["sha256:<hash>"]
nodeRegistration:
  name: "ascend910b-207"
  criSocket: unix:///run/containerd/containerd.sock
  taints:
    - {key: "huawei.com/Ascend910", value: "compute-only", effect: "NoSchedule"}
  kubeletExtraArgs:
    - name: node-ip
      value: "<node ip on the cluster network>"
  ignorePreflightErrors:            # only on a cgroup v1 host
    - SystemVerification
patches:
  directory: /etc/kubernetes/join-patches
EOF

kubeadm join --config /etc/kubernetes/join.yaml && rm -f /etc/kubernetes/join.yaml
```

Why each piece:

- **node name** follows `<accelerator>-<last IP octet>` instead of the vendor hostname.
- **taint at registration**, so no general pod lands in the window before the
  labels go on. Same idea as `script/taint_gpu_nodes.sh` for NVIDIA nodes.
- **kubelet overrides via `patches:`, not by editing afterwards.** kubeadm
  downloads the cluster-wide KubeletConfiguration during the join; by the time
  `/var/lib/kubelet/config.yaml` exists, kubelet is already crash-looping.
  - `failCgroupV1: false` — kubelet ≥ 1.35 refuses to start on cgroup v1 otherwise.
  - `resolvConf: /etc/resolv.conf` — the cluster config points at
    `/run/systemd/resolve/resolv.conf`, which a host without systemd-resolved does
    not have, and then **every** pod sandbox fails with
    `open /run/systemd/resolve/resolv.conf: no such file`. The error names DNS,
    the cause is the file.

If the node is already joined, do not join again — put those same two keys into
`/var/lib/kubelet/config.yaml` and restart kubelet.

## 4. Label the node and deploy the device plugin

Labels first — the device plugin's DaemonSet selects on `workerselector`, and
the `nvidia.com/gpu.deploy.*` ones keep the GPU operator's DaemonSets off a node
that has no NVIDIA card (its validator and toolkit pods otherwise land here and
fail):

```bash
kubectl label node ascend910b-207 --overwrite \
    accelerator=huawei-Ascend910 \
    workerselector=dls-worker-node \
    node.modelsphere.dev/accelerator=ascend-910b \
    nvidia.com/gpu.deploy.operator-validator=false \
    nvidia.com/gpu.deploy.container-toolkit=false \
    nvidia.com/gpu.deploy.device-plugin=false \
    nvidia.com/gpu.deploy.gpu-feature-discovery=false \
    nvidia.com/gpu.deploy.dcgm-exporter=false \
    nvidia.com/gpu.deploy.mig-manager=false
```

The compute-only taint is set at registration (step 3's `JoinConfiguration`); to
reconcile it later use the same script the NVIDIA nodes use, pointed at this resource:

```bash
RESOURCE=huawei.com/Ascend910 bash script/taint_gpu_nodes.sh          # dry-run
RESOURCE=huawei.com/Ascend910 bash script/taint_gpu_nodes.sh --apply
```

Then the plugin itself:

```bash
make ENV=<cluster> helm-diff SELECTOR=name=ascend-device-plugin
make ENV=<cluster> helm-apply SELECTOR=name=ascend-device-plugin
```

The plugin is a helmfile release like every other component, and the chart is
**Huawei's own** (`ascend/mindcluster-deploy-tool-26.1.0.tgz`, MindCluster 26.1.0):

- It is vendored into the repo because it ships as a tgz attached to a GitCode
  release, not from a helm repo — `Ascend-helm-deploy-tool_<ver>_linux.zip`.
  It is kept **as that .tgz**, byte for byte, so "we run the vendor chart
  unmodified" is something a reviewer can check rather than take on trust:

      shasum -a 256 ascend/mindcluster-deploy-tool-26.1.0.tgz
      # 966e9abc74c8dce157fc70c48f99ab563eaa3245a4d5600d0d9f9215b07b2440

  Unpacked it is 131 files nobody reviews in a diff, and a local edit would be
  invisible. To inspect it: `tar xzf ascend/mindcluster-deploy-tool-26.1.0.tgz`.
- It creates the `mindx-dl` and `cluster-system` namespaces unconditionally, with
  `helm.sh/resource-policy: keep` so they survive an uninstall. With only the
  device plugin enabled they just sit there empty. Upstream behaviour; left alone
  on purpose, since patching it would forfeit the point above.
- It is an umbrella over all of MindCluster (device plugin, NodeD, ClusterD,
  NPU-Exporter, Ascend Operator, Infer Operator, its own Volcano build, RDMA
  plugin). `ascend/overrides.yaml` enables **only the device plugin**. Note that
  `ascend-for-volcano` would replace the cluster's existing Volcano release, so
  it is not something to switch on casually.
- `volcanoType: false`, so whole cards are allocated by the default
  kube-scheduler; the chart defaults to `true`, i.e. expecting Volcano.
- The image is pulled from **Docker Hub** (`ascendai/ascend-k8sdeviceplugin`,
  multi-arch). AscendHub's public SWR only serves old tags — v7.1.RC1 and
  v6.0.0 pull anonymously, the v26.1.0 this chart wants does not.
- The chart's DaemonSet selects on `workerselector=dls-worker-node`, Huawei's
  own label convention — hence that label above, next to our own `accelerator`.
- `enabled.ascendDevicePlugin` is **off by default**; turn it on in the
  environment of a cluster that has Ascend nodes.

`smoke-pod.yaml` requests one card and prints `ASCEND_VISIBLE_DEVICES`,
`/dev/davinci*` and `npu-smi` from inside the container — on `ascend-1` it got
a card with only that `/dev/davinciN` and `/dev/davinci_manager` mounted.

## 5. Verify

```bash
kubectl get node ascend910b-207                    # Ready
kubectl get pods -A -o wide --field-selector spec.nodeName=ascend910b-207
kubectl get node ascend910b-207 -o jsonpath='{.status.allocatable}' | jq '."huawei.com/Ascend910"'
kubectl -n kube-system exec <cilium-pod-on-the-node> -c cilium-agent -- cilium-dbg status
```

Three things worth checking explicitly -- each has looked fine while being wrong:

- `cilium-dbg status` reporting `Cluster health 0/0 reachable` is **not** health —
  it means cilium-health has not probed yet. Require a non-zero denominator.
- Node Ready says nothing about the datapath. Run a pod **on this node** and have
  it reach the `kubernetes` Service ClusterIP (kube-proxy replacement) and a pod
  on another node (tunnel). Pick the peer from the pod CIDR — a hostNetwork pod
  carries the node IP and testing against it proves nothing.
- Reading allocatable with jsonpath needs the dots in `huawei.com/Ascend910`
  escaped; unescaped it returns empty, which reads exactly like "no cards".

Then the card itself:

```bash
kubectl apply -f ascend/smoke-pod.yaml && kubectl logs ascend-smoke
```

## Status of `ascend-1` (2026-09-22)

In `the cluster` as `ascend910b-207`, schedulable, step 5's checks **ALL PASS**:
cilium healthy (10/10, kube-proxy replacement on; host routing is Legacy, same
as every other node in this cluster — that follows from the cluster's datapath
config, not from the node), Service ClusterIP and cross-node pod traffic
verified from a pod on the node, `huawei.com/Ascend910: 8` allocatable and a
pod-level `npu-smi` smoke test passing.

Kernel `5.10.0-332.0.0.233.oe2203sp4` (openEuler) on Kylin V10 userspace, with
4.19.90-52.55 still installed as a fallback boot entry. Driver 25.5.0 rebuilt
via DKMS for that kernel — **every future kernel update needs the same rebuild**,
and the distro gcc cannot do it (the node keeps a private gcc 10 for this).
8 cards healthy, `hccn` interconnect IPs unchanged.

A vllm-ascend service (Qwen3-8B on one card) was served end to end on it
through a ClusterIP Service: `/v1/models`, non-streaming and streaming chat all
answered, 16 concurrent requests finished in 6s.

Left over: the old KubeSphere cluster still lists the node as `NotReady` and its
owner has to `kubectl delete node`; `/root/kernel-upgrade*` holds ~1.5G of
staged rpms, the private gcc and build scratch that can be deleted once the node
has run for a while (keep `$WORK/gcc10-shim` if you expect kernel updates —
every future kernel needs the same dkms rebuild).
