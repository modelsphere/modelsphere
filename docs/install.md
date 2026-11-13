# Installing ModelSphere

This guide takes you from bare machines to a model answering requests, step by
step. If you already have a Kubernetes cluster, the quick start in
[the README](../README.md) is shorter.

The diagram shows what you end up with. Requests enter through the routing
layer (openresty, then the cache-aware router), which autoconfig keeps pointed
at the engine pods. The engines (SGLang or vLLM, each with a hang-watcher)
serve them. bodylog records every request, and from those records the scaling
components decide how many engine replicas each model runs.

<p align="center">
  <img alt="ModelSphere architecture" src="../arch/modelsphere.svg" width="900">
</p>

## Deployment, in three parts

**Part A — prepare the machines** (Ansible, from a control machine with SSH)
**Part B — a Kubernetes cluster** (kubeadm) — skip both if you have a cluster
**Part C — the ModelSphere Stack**, which is what this repository is for

| | Step | Command | Skip it when |
|---|---|---|---|
| A | 1. Prerequisites | `make helm-deps` | never -- but of its three tables, only the first applies when you already have a cluster |
| A | 2. Node prep | `make setup-all` | the nodes already run a cluster, or another tool prepared them |
| A | 3. GPU node prep | `make gpu-prep` | the driver and container toolkit are already installed |
| B | 4. Create the cluster | `kubeadm init` / `join` | you already have a cluster |
| C | 5. Cluster prerequisites | `make helm-bootstrap` | no Gateway, no PriorityClass of yours, and `cilium.gatewayAPI` left off (the default) |
| C | 6. Install the stack | `make helm-apply ENV=<env>` | never -- this is the step |
| C | 7. Gateway objects | `kubectl apply -f gateway-api/openresty/` | the routing layer only serves traffic inside the cluster |
| C | 8. Deploy a model | `helm install` | you are installing infrastructure now and models later |

Each step below repeats its own skip condition, so you can read from wherever
you are starting.

This walkthrough assumes the machine you type from, and the cluster, can reach
the internet. A cluster that cannot does the same steps with a prologue of its
own: [`offline-install.md`](offline-install.md).

---

## Part A — Prepare the machines

### 1. Prerequisites

On the machine you type from, for **Part C** — installing the stack on any
cluster:

| Requirement | How to get it |
|---|---|
| `kubectl`, pointed at that cluster | `kubectl config current-context` |
| helm ≥ 3.8 and helmfile ≥ 1.0 | install them yourself; tested on helm v4.3.0 + helmfile 1.8.0 |
| the helm-diff plugin | `make helm-deps` -- once per machine, and not optional: `helmfile apply` shells out to it |

And for **Parts A and B** — preparing machines and creating a cluster. Skip
these if you already have one:

| Requirement | How to get it |
|---|---|
| Ansible ≥ 2.15 | `ansible-galaxy collection install community.general ansible.posix` |
| passwordless SSH + sudo to every node | and their host keys accepted: `ssh-keyscan -H <node> >> ~/.ssh/known_hosts` |
| an inventory file | copy `inventory.ini.example` to `inventory.ini`, which is the default; `INVENTORY=` picks another |

On the nodes, also Parts A and B only — a cluster that exists already has
whatever it has:

| Requirement | What it means |
|---|---|
| Ubuntu 22.04 or newer | what the playbooks are written against. Its 5.15 kernel also clears what our Cilium needs (kernel ≥ 5.10, cgroup v2) -- not a requirement if you run another CNI. On another distro check both, separately: `uname -r`, and `stat -fc %T /sys/fs/cgroup` must say `cgroup2fs`. Cilium reports either one missing as the same error, `Require support for bpf_get_current_cgroup_id()`, whatever kernel version it names |
| storage | nothing by default -- the monitoring stack runs on emptyDir. ⚠️ Metrics, alert state and anything saved in Grafana's UI are lost when one of those pods restarts |
| a spare raw block device on 3+ nodes | only if you want durable storage; see [`helmfile-deploy.md`](helmfile-deploy.md#storage) |
| a node that is not Ubuntu/amd64/NVIDIA | goes through the same playbook with `k8s_install_method=binary` instead of apt, and needs a Python new enough for Ansible plus its own accelerator driver on the host. Procedure: [`add-ascend-node.md`](add-ascend-node.md) |

---

### 2. Node prep (Ansible)

*Skip to step 3 when the nodes already run a cluster, or another tool prepared
them.*

*A node with no route to the internet cannot run `setup-all`, which installs
packages: see
[`offline-install.md`](offline-install.md#node-packages-before-any-of-this)
for which tags to run instead.*

What a node gets:

| | Component | From | Version knob |
|---|---|---|---|
| packages | `kubelet` `kubeadm` `kubectl` `cri-tools` | Kubernetes apt repo | `k8s_apt_channel` (`v1.36`) |
| | `containerd.io` | Docker apt repo, pinned | `k8s_containerd_version` (`2.3.5-1`) |
| | `docker-ce` `docker-ce-cli` | Docker apt repo | — |
| | HWE kernel, only below the floor | Ubuntu | `k8s_min_kernel` (`5.10`), `k8s_install_hwe_kernel` |
| config | `/etc/hosts`, swap off, kernel modules, sysctls | — | — |
| | containerd `config.toml`: SystemdCgroup, pull timeout, NOFILE, `certs.d` path | — | — |
| opt-in | data disk mounted, `/var/lib/{docker,containerd}` moved onto it | — | `k8s_data_disk`, `data_mount` (`/mnt/disk0`) |

**A node that already has them is left alone.** Package tasks are
`state: present`, never `latest`, and everything ends up `apt-mark hold`-ed. An
existing `containerd.io` at another version is reported, not replaced -- changing
it restarts the container runtime, so that stays a deliberate act.

The data disk is a site decision -- a node may have no spare one -- so
`setup-all` skips it and says so.

```bash
make setup-all                                # this is the step
```

Variations on it, not extra steps:

```bash
make setup-all SETUP_DISK=1                   # + the data disk
make setup-all LIMIT=10.0.0.5                 # one host or group

# or one task at a time, instead of setup-all
make setup-k8s-online     # the packages
make setup-k8s-offline    # the configuration
make setup-disk           # the data disk
```

`online` downloads, `offline` only configures -- that is all the tag names mean,
and the first needs a route out. What each node ends up with, what to do on an
older distribution, and what to do when a task refuses:
[`node-prep.md`](node-prep.md).

---

### 3. GPU node prep (Ansible)

*Skip to step 4 when the driver and container toolkit are already installed --
`make audit-gpu` says whether they are, and changes nothing.*

```bash
make gpu-prep                   # this is the step -- the `gpu` inventory group
```

```bash
make gpu-prep LIMIT=gpu-h100    # or just one host
make audit-gpu                  # read-only check, any time: non-zero when something is missing
```

`gpu-prep` makes GPUDirect RDMA work and keeps it working: RDMA and
`nvidia_peermem` modules loaded and persisted, GPU persistence mode on,
`nvidia-fabricmanager` started on NVSwitch hosts, and the PCIe ACS redirect
cleared on every boot.

It needs nothing set, on a GPU node with an RDMA NIC or without one:
`rdma_fabric` defaults to `auto`, which skips the RDMA-only steps where there is
no RDMA device. What that covers, what ACS costs when it is on, and what
`audit-gpu` checks: [`node-prep.md`](node-prep.md#gpu-nodes).

---

## Part B — A Kubernetes cluster

*Any conformant cluster works. This is the way we build ours; the official
instructions are at [kubernetes.io](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/).*

### 4. Create the cluster (kubeadm)

*Skip to step 5 when you already have a cluster.*

The smallest init that works with Cilium, which is the CNI this stack installs
unless you turn it off -- one node, and no kube-proxy because Cilium replaces
it:

```bash
kubeadm init --pod-network-cidr=<podCIDR> --skip-phases=addon/kube-proxy
mkdir -p ~/.kube && cp -f /etc/kubernetes/admin.conf ~/.kube/config
kubectl taint node <node> node-role.kubernetes.io/control-plane-   # see below
```

Set `cilium.podCIDR` in your environment file to that same `<podCIDR>`, and pick
one that is unique across clusters that will ever route to each other. The two
are read by different things -- this flag is what kube-controller-manager
records, while `cilium.podCIDR` is what the Cilium operator actually hands
addresses out of -- so a cluster where they differ has two notions of its own
pod network.

**Remove the taint when anything has to run on the control-plane node** --
always on a single-node cluster, and on any cluster whose GPUs are on a
control-plane node. kubeadm taints it `NoSchedule`, and most charts here do not
tolerate that. Left on, a GPU node advertises no `nvidia.com/gpu` and model
pods stay `Pending`, with no event naming a taint.

The cluster comes up with **no CNI and no kube-proxy**: nodes stay `NotReady`
and CoreDNS `Pending` until step 6. That is expected.

A cluster built this way needs `enabled.cilium: true` in its environment file:
the repo default is false, for the clusters that already have a CNI.

**Bringing your own CNI instead?** Leave `enabled.cilium` alone, keep kube-proxy
(drop `--skip-phases`), and take the pod CIDR from that CNI's own requirements
rather than from `cilium.podCIDR`.

Three control planes, a real init config and the join commands:
[`kubeadm-cluster-init.md`](kubeadm-cluster-init.md).

---

## Part C — The ModelSphere Stack

### What your cluster needs

Two things, whatever you install:

| Requirement | What it has to be |
|---|---|
| **Kubernetes ≥ 1.25** | the strictest `kubeVersion` among the charts (kube-prometheus-stack); without monitoring it is 1.21 |
| **a CNI** | any one, including none yet: a cluster built by Part B has no CNI until step 6 installs Cilium. Bring your own and turn Cilium off |

Everything else belongs to a component, and applies only if you install it:

| Installing | needs |
|---|---|
| **Cilium** | **no kube-proxy** — we set `kubeProxyReplacement`, so Cilium's eBPF does Service load balancing and kube-proxy must not too. That leaves the agent unable to reach the apiserver through the `kubernetes` ClusterIP, so `cilium.k8sServiceHost` must carry its real address. Also a pod CIDR matching `cilium.podCIDR` (Cilium's IPAM pool), and kernel ≥ 5.10 with cgroup v2 for that datapath |
| the shipped **Gateway objects** | the Gateway API CRDs and a Gateway API implementation -- ours is Cilium's, named in one line, `gatewayClassName:` in `gateway-api/openresty/gateway-openresty.yaml`. **They are optional**: the Gateway is not part of this stack, only one way to expose the routing layer. On another CNI, either point that line at your own implementation or skip the Gateway and expose the `openresty` Service however you already expose things |
| **kube-prometheus-stack** | port 9100 free on every node (node-exporter binds it on the host) |
| **bodylog** | `llmGateway.node` and `llmGateway.hostPath` -- it keeps its records on one node's local disk |
| model values that name a **PriorityClass** | `make helm-bootstrap`, which creates them. The engine charts default to none |

Every component is a key of its own under `enabled:` in the environment file,
set to `true` or `false` -- GPUs, RDMA, Ceph, LeaderWorkerSet, Volcano,
monitoring and the routing layer alike:

```yaml
enabled:
  gpuOperator: true        # on by default
  networkOperator: true    # RDMA / GPUDirect
  lws: true                # multi-node inference
  rookCeph: false          # storage: off by default
  rookCephCluster: false
```

`environments/default.yaml` lists them all with what each one costs when it is
on; a cluster that already has its own comments them down to `false`.

### On a cluster you already have

A cluster with its own CNI, its own GPU device plugin, its own scheduler and
storage needs **only the inference modules** -- the routing layer, the autoscaler
and the engines. Everything else in the table below is turned off, which is one
block in the environment file:

```yaml
enabled:
  # Already there, or not wanted. cilium is off in default.yaml already.
  gpuOperator: false       # the cluster has its own device plugin
  networkOperator: false
  nicClusterPolicy: false
  kubePrometheusStack: false
  llmAlerts: false
  llmDashboards: false
  alertWebhook: false
  nodeProblemDetector: false
  condition2taint: false
  descheduler: false
  volcano: false
  lws: false               # unless you run multi-node inference
  rookCeph: false
  rookCephCluster: false
  cephCsiDrivers: false
  llmCanaryOperator: false

  # What you came for.
  openresty: true
  autoconfig: true
  llmOperator: true
  llmslo: true
  bodylog: false           # needs llmGateway.node + llmGateway.hostPath first:
                           # it keeps its records on one node's local disk
  bodylogExporter: false

storage:
  persistence: false
```

Point `registry` and `chartRepo` at something that cluster can pull from, and
if it has its own prometheus-operator set `autoconfig.serviceMonitor: true` --
left empty it follows `enabled.kubePrometheusStack`, so without monitoring no
ServiceMonitor is rendered and the apply does not fail on a CRD that is not
there.

**What lands on the cluster:** three namespaces of ours (`llm-route`,
`llm-scaler`, `llmscaleoperator-system`) plus one per model, and -- the part
worth reviewing before you run it on a cluster you share -- a handful of
ClusterRoles and ClusterRoleBindings under our own names, and the CRDs for
model routing and autoscaling. Their API groups move with the chart versions
`versions:` pins, so read them off your own render rather than from here:
`make helm-diff` shows all of it, CRDs included, before anything is applied.

**Steps 5 and 7 are optional here.** `make helm-bootstrap` installs the Gateway
API CRDs and the PriorityClasses -- needed only if you use the Gateway objects in
step 7, or if your model values name a PriorityClass. The routing layer serves
through its own Service either way; the Gateway is for exposing it outside the
cluster. Without Cilium you do not need it at all: point `gatewayClassName:` in
`gateway-api/openresty/gateway-openresty.yaml` at your own Gateway API
implementation, or leave step 7 out and put an Ingress, a LoadBalancer Service
or whatever you already use in front of the `openresty` Service.

---

### 5. Cluster prerequisites

*Skip to step 6 when none of the three apply: you expose the routing layer some
other way, no values of yours name a PriorityClass, and you have not turned
`cilium.gatewayAPI` on (off by default; on, Cilium needs these CRDs too). Both
objects are cluster-wide -- installed once per cluster, not once per
person.*

```bash
make helm-bootstrap   # Gateway API CRDs + PriorityClasses
```

`helm-bootstrap` is plain `kubectl apply` for the two things no chart owns:

- **Gateway API CRDs** — needed by two independent things: the Gateway objects
  in step 7, and Cilium itself when `cilium.gatewayAPI` is on, which is off by
  default. With it on, Cilium checks for them before it installs and fails the
  release when they are missing, so skipping this step then breaks step 6 even
  if you never do step 7.
- **PriorityClasses** — needed only if your own values name one. The engine
  charts default to none.

---

### 6. Install the stack

*Not skippable: this is the step the repository exists for.*

⚠️ **This writes to the cluster, and the defaults are for a cluster being built
from scratch**: `environments/default.yaml` switches on eighteen components,
among them a CNI, a GPU operator, a scheduler and a monitoring stack. On a
cluster that has its own, turn them off in your environment file first —
[On a cluster you already have](#on-a-cluster-you-already-have) is that block,
ready to copy. `make helm-diff ENV=<env>` lists everything an apply would
create, and changes nothing.

```bash
make helm-apply ENV=<env>
```

That is the whole step. It begins with `helm repo update`, so a control machine
that has never added the chart repositories gets them; `SKIP_REFRESH=1` skips
that on one that refreshed a moment ago.

`<env>` is a name registered under `environments:` in `helmfile.yaml.gotmpl`,
not just a file in `environments/`. 

```yaml
environments:
  mycluster:
    values:
      - environments/default.yaml     # the base layer, then your overrides
      - environments/mycluster.yaml
```

One apply installs everything you switched on, in the order `needs:` gives.

**On a cluster that already has a CNI**, `enabled.cilium` stays at its default,
false, and this step installs no CNI at all -- the releases that would have
waited for it simply do not.

**On a cluster being built from Part B**, set it to `true`: cilium is then the
one release the apply waits for (`wait: true`), so nodes that are still
`NotReady` when you start converge in the same pass rather than needing a second
one.

If a release fails on a CRD it does not own, run it again -- the CRDs exist by
the end of the first run. `docs/helmfile-deploy.md` explains why.

**What it installs, and how to check each one.** Any row can be installed,
diffed or re-applied on its own -- `SELECTOR` is passed to helmfile as `-l`:

```bash
make helm-apply ENV=<env> SELECTOR=name=cilium        # one release
make helm-apply ENV=<env> SELECTOR=tier=observability # or a group: cni, storage,
                                                      # observability, gpu, llmgate,
                                                      # operator, scheduler, model
```

| Release | `tier` | Whose | Turn it off when | Check it came up |
|---|---|---|---|---|
| `openresty` | `llmgate` | ModelSphere | -- it is the routing layer | `kubectl -n llm-route get deploy openresty` |
| `autoconfig` | `llmgate` | ModelSphere | -- it feeds the routing layer | `kubectl -n llm-route get deploy autoconfig`, and `kubectl get modelroutes -A` once a model is in |
| `bodylog`, `bodylog-exporter` | `llmgate` | ModelSphere | you do not want per-request records, or have nowhere to keep them (they need a node and a local path) | `kubectl -n llm-route get pods -l app.kubernetes.io/name=bodylog` |
| `llmscaleoperator`, `llm-slo` | `operator` | ModelSphere | you scale by hand | `kubectl -n llmscaleoperator-system get deploy`, `kubectl -n llm-scaler get pods` |
| `llm-canary-operator` | `operator` | ModelSphere | you do not run canaries | `kubectl -n llm-canary-operator-system get deploy` |
| `alert-webhook` | `observability` | ModelSphere | your alerts go somewhere else | `kubectl -n monitoring get deploy alert-webhook` |
| `cilium` | `cni` | upstream | **the cluster already has a CNI** | `kubectl -n kube-system get ds cilium` -- and every node `Ready` |
| `kube-prometheus-stack` | `observability` | upstream | the cluster already has Prometheus, or you want none | `kubectl -n monitoring get pods` -- prometheus, alertmanager, grafana |
| `gpu-operator` | `gpu` | upstream | **the cluster already advertises GPUs** (its own device plugin) | `kubectl get node <gpu node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'` |
| `network-operator` | `gpu` | upstream | no RDMA fabric | `kubectl -n nvidia-network-operator get pods` |
| `lws` | `gpu` | upstream | no multi-node inference | `kubectl -n lws-system get deploy` |
| `volcano` | `scheduler` | upstream | the cluster already has a scheduler you use | `kubectl -n volcano-system get pods` |
| `descheduler` | `observability` | upstream | you do not want pods moved for you | `kubectl -n kube-system get cronjob descheduler` |
| `node-problem-detector`, `condition2taint` | `observability` | upstream, ModelSphere | node faults are somebody else's monitoring | `kubectl -n node-problem-detector get ds`, `get deploy condition2taint` |
| `rook-ceph`, `rook-ceph-cluster`, `ceph-csi-drivers` | `storage` | upstream | the cluster has a StorageClass, or you want none -- **off by default** | `kubectl get sc` |

Or all at once: `helm list -A` should show every enabled release `deployed`, and
`kubectl get pods -A` nothing outside `Running`/`Completed`.

Which of them are installed is `enabled:` in `environments/<env>.yaml`, layered
over `environments/default.yaml`; what each release reads is in
[`helmfile-deploy.md`](helmfile-deploy.md). Where the code lives is the
table at the top of this file.

One thing about the cluster decides whether this converges:

- **Storage is off by default** (`storage.persistence: false`), so Prometheus,
  Alertmanager and Grafana run on emptyDir. ⚠️ **A pod restart or reschedule
  loses what it held** -- metrics, silences, and anything saved in Grafana's UI;
  dashboards provisioned from ConfigMaps come back by themselves. To get durable
  storage -- Ceph as shipped, or your own StorageClass -- see
  [`helmfile-deploy.md`](helmfile-deploy.md#storage).

Changing something later is the same command again: `helm-apply` brings the
cluster to whatever the files now say. Which is to say this step is not
one-way -- [`helmfile-deploy.md`](helmfile-deploy.md#day-to-day) is
the upgrade, diff and rollback side of it.

---

### 7. Gateway objects

*Skip to step 8 when the routing layer only serves traffic from inside the
cluster.* It has a Service either way; this step is what puts it on an address
outside.

**A request through the Gateway carries the route name in its path**:
`/<route>/v1/chat/completions`, not `/v1/chat/completions`. The routing layer
dispatches on that prefix, and the route name is the model release's name --
`qwen` for the example in step 8 -- which is not always the model name. Without
it the request matches no route and comes back 502 from openresty, with every
component healthy.

`gateway-api/openresty/` holds a Gateway and an HTTPRoute for the routing
layer. No chart owns them, so they go on with `kubectl`.

**Skip this step if you expose the routing layer some other way.** The Gateway
belongs to your cluster's edge, not to this stack; the routing layer serves
through its `openresty` Service whether or not anything fronts it.

This comes after step 6, not with step 5, because these objects point at things
step 6 creates: the HTTPRoute's backend is the `openresty` Service, and the
Gateway asks for a `gatewayClassName`. Step 5 installs the CRDs -- the types
themselves -- which depend on nothing and so can go first.

**Something has to implement that class, and by default nothing does.** The
shipped Gateway asks for `gatewayClassName: cilium`, and Cilium only registers
that GatewayClass with `cilium.gatewayAPI: true`, which is off in
`default.yaml`. Turn it on before step 6 (together with step 5's CRDs, which
Cilium then requires), or point `gatewayClassName:` at the Gateway API
implementation your cluster already runs. With neither, `kubectl apply`
succeeds, the Gateway is never programmed, and nothing says why:

```bash
kubectl get gatewayclass                      # is there one your Gateway can use?
kubectl -n llm-route get gateway openresty -o jsonpath='{.status.conditions}'
```

```bash
kubectl apply -f gateway-api/openresty/
```

Name the subdirectory, not `gateway-api/` -- `kubectl apply -f <dir>` does not
recurse, so applying the parent exits 0 and creates nothing.

**Set the hostname to yours first.** `httproute-openresty.yaml` carries the
hostname of the cluster it was written for, and a route only matches requests
whose `Host` header is that name. Left as it is, it matches nothing and the
gateway answers 404.

**HTTP works as applied.** Nothing further is needed for a cluster that serves
plain HTTP.

**HTTPS needs a certificate you supply.** The https listener in
`gateway-openresty.yaml` names a Secret under `certificateRefs`; create it with
your own certificate, in the `gateway-secrets` namespace that ships with these
objects:

```bash
kubectl -n gateway-secrets create secret tls <name from certificateRefs> \
  --cert=<fullchain.pem> --key=<privkey.pem>
```

Until that Secret exists the https listener does not serve, which is harmless
while nothing uses it.

Why the Gateway can look dead when it is not, and what to check instead:
[`helmfile-deploy.md`](helmfile-deploy.md).

---

### 8. Deploy a model

This walks through one small model end to end -- Qwen2.5-0.5B-Instruct on a
single GPU -- as the worked example. It is the same path any model takes: put
the weights on a node, install an engine over them, ask it a question.

**1. Put the weights on each GPU node's local disk**, one directory per model:

```
/mnt/disk0/models/<org>/<model>      # e.g. /mnt/disk0/models/Qwen/Qwen2.5-0.5B-Instruct
```

A copy per node, on local disk, is the assumption here — load time is what
decides how long a restart or a scale-up takes, and tens of gigabytes of weights
read over a network filesystem make that worse than the disk does. That path is
the node's data mount (step 2, `data_mount`); on a node without one, use any
local path and point `model.localPath` at it. Copying the weights is not this
repository's job.

Shared storage — CephFS, NFS — is not supported: `model.localPath` is a
hostPath.

**2. Install an engine over them.** The engines are published charts, so this is
an ordinary `helm install`:

```bash
helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm upgrade --install qwen modelsphere/sglang \
  --namespace llm-demo --create-namespace -f <your values.yaml>
```

`models/examples/sglang-qwen.yaml` is a complete working example -- one
Qwen2.5-0.5B-Instruct on one GPU with the cache-aware router and the
hang-watcher sidecar -- and its `values:` block is what goes in `-f`. The values
themselves are the chart's, documented with it in
[modelsphere/helm-charts](https://github.com/modelsphere/helm-charts) (`sglang`,
or `vllm` for the other engine).

**3. Check it serves.** The engine pod is `2/2` (engine + hang-watcher) and each
router pod `3/3`.

While the engine image is still being pulled, **the router pods CrashLoopBackOff
with `Failed to read config file '/workspace/configs/workers.yaml'`, and that is
the expected state, not a fault**: there is no engine to route to yet, so
autoconfig has no worker list to write, and the routers restart until there is
one. An engine image is ~15-19 GB, so on a cluster pulling it from the internet
this window is comfortably over half an hour. It clears itself.

```bash
kubectl -n llm-demo get pods
kubectl -n llm-demo exec deploy/qwen -c sglang -- curl -s localhost:30000/v1/models
kubectl -n llm-demo exec deploy/qwen -c sglang -- curl -s qwen-cart:8071/v1/models
kubectl -n llm-demo exec deploy/qwen -c sglang -- \
  curl -s localhost:30000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",
       "messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

The first call asks the engine directly; the one against `qwen-cart:8071` goes
through the router, so an answer there also means autoconfig has written the
worker list into the router's ConfigMap. A pod that is Running but answers
neither is usually still loading weights.

This needs `gpuOperator` from step 6 -- without it the node advertises no
`nvidia.com/gpu` and the pod stays `Pending`:

```bash
kubectl get node <gpu node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

---

## Makefile reference

```bash
make help
```

| Variable | Default | Meaning |
|---|---|---|
| `INVENTORY` | `inventory.ini` | which inventory Ansible reads |
| `LIMIT` | `all` | restrict Ansible to a host, IP or group |
| `ENV` | `default` | which `environments/<ENV>.yaml` helmfile loads |
| `SELECTOR` | empty | passed to helmfile as `-l`, e.g. `tier=gpu`, `name=cilium` |
| `SKIP_REFRESH` | *(empty)* | `helm repo update` runs; set it to `1` to skip on a machine that refreshed a moment ago |
| `SETUP_DISK` | empty | `make setup-all` also mounts the data disk |
| `SKIP_DEPS` | empty | skip `helm repo add`; needed only with no outbound network |
| `INTERACTIVE` | `true` | helmfile asks before applying |

`ENV` is not inferred from your kubeconfig — helmfile talks to whatever
`kubectl config current-context` points at, while `ENV` decides which values it
renders. **Getting them out of step is possible and will not warn you**, so check
both before an apply against a live cluster.

## Accelerators that are not NVIDIA

ModelSphere runs on other accelerators. The path is step 2's node preparation,
with `k8s_install_method=binary` for a node that is not Ubuntu/amd64, and the
vendor's device plugin in place of NVIDIA's -- an ordinary helmfile release, off
unless a cluster has such a node.

Ascend NPUs are the ones this has been walked on end to end:
[`add-ascend-node.md`](add-ascend-node.md).
