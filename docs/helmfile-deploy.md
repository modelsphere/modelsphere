# Installing the stack with helmfile

This is the reference behind
[Part C of the install guide](install.md#part-c--the-modelsphere-stack). That
guide is the path to follow; come here to change what is installed, add a
cluster, or work out why an apply did something unexpected.

Everything the cluster runs on top of Kubernetes — the routing layer,
monitoring, the GPU and RDMA operators, LeaderWorkerSet, storage — is one
declarative file:

```
helmfile.yaml.gotmpl        # releases, ordering, hooks
environments/default.yaml   # versions, namespaces, enable flags
```

## What helmfile does not do

| | Where |
| --- | --- |
| Node prep (kernel, containerd; disks opt-in) | Ansible — `make setup-all` (`SETUP_DISK=1`) |
| RDMA / `nvidia_peermem` / ACS on GPU nodes | Ansible — `make gpu-prep` |
| `kubeadm init` / `join` | [`kubeadm-cluster-init.md`](kubeadm-cluster-init.md) |
| Gateway / HTTPRoute objects | `gateway-api/` — `kubectl apply` |
| Inference workloads | their own repos |

The CNI is *not* on that list: helmfile installs cilium along with everything
else. See [Cilium](#cilium).

## Prerequisites

- **helm ≥ 3.8** (helm 4 works too) -- OCI support, since `chartRepo` may be an
  `oci://` registry
- **helmfile ≥ 1.0** -- this state file's syntax
- the **helm-diff** plugin (`make helm-deps`), which `helmfile apply` and
  `helmfile diff` both shell out to

The versions the bundle installs are in `offline/versions.env`; see
[install step 1](install.md#1-prerequisites).

helmfile talks to whatever your current kubecontext points at, while `ENV`
decides which values it renders. Check the first before an apply:

```bash
kubectl config current-context
```

## The first run

The path itself is [Part C](install.md#part-c--the-modelsphere-stack) —
`make helm-bootstrap`, then `make helm-apply ENV=<env>` — and this
document deliberately keeps no second copy of it. What belongs here is what
makes run 1 different from every run after it.

**With `enabled.cilium: true` -- which a cluster that needs a CNI must set,
since the default is false -- one apply installs everything including the
CNI**, on a cluster whose nodes are still `NotReady`. (A cluster that brought
its own CNI sets that to `false`, and none of what follows applies to it: there
is nothing to wait for.) Most releases do not care: their objects are created
and their pods sit `Pending` until the CNI arrives, then schedule. Only two
edges are needed, and `helmfile apply` walks them from `needs:`:

- **cilium is the one release the apply waits for** (`wait: true`), so anything
  that depends on it starts against a cluster whose nodes are `Ready`.
- **kube-prometheus-stack needs cilium**, because its install runs hook Jobs
  (the admission webhook certificates) and a Job cannot be scheduled before the
  CNI is up. It also needs `rook-ceph-cluster` when storage is on, for the
  StorageClass its PVCs bind.

**`helm repo update` runs by default.** `SKIP_REFRESH=1` passes
`--skip-refresh`, which is worth it on a machine that refreshed a moment ago and
wrong on one that has never added the repositories, where the command dies with
`Error: repo cilium not found`. It used to be the default, and that first run is
what it cost.

**A release can fail on a CRD another release in the same run owns. Run the
apply again.** `helmfile apply` diffs before it syncs, and helm-diff renders each
release against the API **as it is when the run starts**. A chart that references
a CRD that does not exist yet therefore cannot render, and the apply stops before
installing anything:

```
no matches for kind "PrometheusRule" in version "monitoring.coreos.com/v1"
ensure CRDs are installed first
```

That is node-problem-detector wanting CRs that kube-prometheus-stack creates.
`needs:` orders the apply, not the render, so no reordering fixes it. The CRDs
exist by the end of the first run, so the second run goes through. To get through
in one run instead, call helmfile directly with `--skip-diff-on-install` — the
Makefile target does not pass it — which skips the diff for releases that are not
installed yet:

```bash
helmfile -f helmfile.yaml.gotmpl -e <env> apply --skip-diff-on-install
```

⚠️ Not `--skip-diff-validation-on-install`. It also disables the API validation
that populates `.Capabilities.APIVersions`, so a chart that gates on capabilities
— Cilium's ServiceMonitor check, for one — then fails to render even when the CRD
is present. See [Cilium](#cilium).

**`rook-ceph-cluster` returns immediately** (`wait: false`), because mons and
OSDs converge asynchronously. Watch it separately, and do not read a
not-yet-`HEALTH_OK` cluster as a failed apply:

```bash
kubectl -n rook-ceph get cephcluster -w
```

## Day-to-day

```bash
make helm-diff                              # everything
make helm-diff  SELECTOR=tier=gpu           # one tier
make helm-apply SELECTOR=name=descheduler   # one release
make helm-list                              # what this repo declares (file only)
make helm-status                            # declared vs what is really in the cluster
make helm-template                          # render locally, no cluster
```

Labels available to `SELECTOR`: `tier` (`cni`, `storage`, `observability`, `gpu`,
`llmgate`, `scheduler`) and `name`.

Changing a component is a two-file job at most: edit its `overrides.yaml`, bump
its version in `environments/default.yaml`, `make helm-diff`, `make helm-apply`.

Unless the environment pins that chart itself. A cluster's own file carries its
own `versions:` for the charts whose Kubernetes API groups moved, so a bump in
`default.yaml` is invisible to them — and moving them is a migration with an
order to it, not a version bump. `make helm-diff ENV=<env>` is what tells you
which of the two you are doing.

`helm-list` reads `helmfile.yaml.gotmpl` and nothing else — it cannot tell you a
release is absent, failed, or running last month's chart. `helm-status` joins it
with `helm list -A` from the live cluster and labels every release:

| Verdict | Meaning | Fix |
| --- | --- | --- |
| `missing` | declared and enabled, helm has no such release | `make helm-apply` |
| `drift` | deployed chart version != the declared version | `make helm-apply` |
| `failed`, `pending-upgrade`, ... | present, but helm status is not `deployed` | investigate before applying |
| `extra` | `installed: false` here, still on the cluster | `helm-apply` **uninstalls** it |
| `unmanaged` | on the cluster, not in this helmfile at all | adopt it here, or remove it |
| `ok` / `off` | declared and deployed / off and absent, as intended | — |

It compares presence and chart version only; `make helm-diff` is what compares
values. `ENV=` and `SELECTOR=` work the same as everywhere else, and
`make helm-status ARGS=--json` emits the same rows as JSON. Under a `SELECTOR`
the `unmanaged` check is suppressed — everything outside the selector would
otherwise look unmanaged.

## Which file holds what

`environments/default.yaml` is the **base layer for every environment**, not just
`default`. Each cluster file is layered on top and carries only what differs, so
a cluster's own file is a couple of dozen lines rather than a copy. helmfile
merges left to right: maps merge key by key, **lists are replaced wholesale**
(which is what you want for `ceph.nodes`).

Six releases read their values through a template instead of a flat file,
because their values contain per-cluster facts:

| Release | Values file | Environment key |
|---|---|---|
| `cilium` | `cni/overrides.yaml.gotmpl` | `cilium:` — control-plane endpoint, pod CIDR, ServiceMonitors on/off |
| `rook-ceph-cluster` | `ceph/ceph-cluster-override.yaml.gotmpl` | `ceph:` — node/device topology, dashboard host |
| `bodylog` | `llmgateway/bodylog-overrides.yaml.gotmpl` | `llmGateway:` — the node and directory the sinks live on, memory limit, token |
| `bodylog-exporter` | `llmgateway/bodylog-exporter.yaml.gotmpl` | `llmGateway:` — the same node and directory, ServiceMonitor on/off |
| `kube-prometheus-stack` | `observability/prom-stack/overrides.yaml.gotmpl` | `storage:` — the StorageClass name, and whether the four PVCs exist at all |
| `alert-webhook` | `observability/alert-webhook/config.yaml.gotmpl` | `alertWebhook.urls`, `name` — the notification targets and the cluster label |

Everything *not* templated in those files is a deliberate stack-wide
decision (kubeProxyReplacement, the Hubble metric set, the envoy connection
ceilings, `useAllNodes: false`). If one cluster needs to differ on one of them,
lift that key into the environment file — do not fork the template.

To see what a given environment actually renders:

```bash
helmfile -e b300 write-values -l name=cilium --output-file-template '/tmp/{{ .Release.Name }}.yaml'
```

## Adding a cluster

```bash
cp environments/default.yaml environments/mycluster.yaml   # keep only what differs
```

Register it under `environments:` at the top of `helmfile.yaml.gotmpl` (there is
a commented example), then:

```bash
make helm-diff ENV=mycluster
```

### Adopting an already-installed release

helmfile keys a release on **name + namespace**. If a release is already on the
cluster under the same name and namespace, `helmfile apply` upgrades it in
place — which is the point. If it is under a *different* namespace, you get a
second copy rather than a move. So before the first apply on a live cluster:

```bash
make helm-status
```

and reconcile the `namespaces:` block in `environments/default.yaml` with what
you see — an already-installed release sitting in a different namespace shows up
as `missing` (the declared one) plus `unmanaged` (the real one), which is the
signal to fix the namespace here rather than apply and get two copies.

## Where the charts come from

Nothing resolves to a local directory. The vendored chart trees and tarballs in
this repo (`cni/cilium/`, `nvidia/gpu-operator/`, `observability/*/`,
`scheduler/volcano/volcano-1.15.1.tgz`) stay as reference and offline copies —
useful for reading templates, diffing between versions, and installing by hand —
but helmfile pulls the real thing:

| Release | Source | Version |
| --- | --- | --- |
| `cilium` | `https://helm.cilium.io/` | `1.20.0` |
| `rook-ceph`, `rook-ceph-cluster` | `https://charts.rook.io/release` | `v1.20.3` |
| `ceph-csi-drivers` | `https://ceph.github.io/ceph-csi-operator` | `1.0.4` |
| `kube-prometheus-stack` | `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack` | `87.21.0` |
| `node-problem-detector` | `oci://ghcr.io/deliveryhero/helm-charts/node-problem-detector` | `2.4.1` |
| `descheduler` | `https://kubernetes-sigs.github.io/descheduler/` | `0.36.0` |
| `gpu-operator` | `https://helm.ngc.nvidia.com/nvidia` | `v26.3.3` |
| `network-operator` | `https://helm.ngc.nvidia.com/nvidia` | `26.4.1` |
| `lws` | `oci://registry.k8s.io/lws/charts/lws` | `v0.9.0` |
| `openresty`, `bodylog`, `bodylog-exporter` | `chartRepo` (environment value: public GitHub Pages / internal ChartMuseum) | see `versions:` |
| `autoconfig`, `llm-slo-decision-gen`, `llmscaleoperator` | `chartRepo` (same) | see `versions:` |
| `condition2taint`, `alert-webhook`, `llm-canary-operator` | `chartRepo` (same) | see `versions:` |
| `console` | `chartRepo` (same) | see `versions:` |
| `volcano` | `https://volcano-sh.github.io/helm-charts` | `1.15.1` |

Versions are not repeated here on purpose: they live in `versions:` in
`environments/default.yaml`, and an environment may pin its own (a cluster file
b300 do, for the charts whose Kubernetes API groups moved). A table of numbers
here would be a second place to forget.

That table describes `registryMode: upstream`. In either offline mode the
upstream repositories are dropped from `repositories:` and every chart comes
from `chartsDir` as a `.tgz` the bundle carried — an air-gapped cluster resolves
no chart over the network at all. See [offline-install.md](offline-install.md).

⚠️ **The NVIDIA repo alias is `nvidia-ngc`, not `nvidia`** — deliberately.
helmfile resolves a chart reference as a local path before a repo alias, and
this repo has `nvidia/gpu-operator/` and `nvidia/network-operator/` on disk, so
`chart: nvidia/gpu-operator` would silently install the vendored copy instead of
the one from NGC. Keep the alias distinct from any top-level directory name.

## Cilium

`enabled.cilium` is **false** in `default.yaml`, because most clusters arriving
here have a CNI already. The cost of that default falls on the clusters whose
cilium this helmfile installed: for them an environment that leaves it false --
or simply never mentions cilium -- gets a full sync that
**UNINSTALLS the running CNI** (every pod into
ContainerCreating with "unable to connect to Cilium agent", node NotReady). On a
cluster whose cilium this helmfile already owns, a sync reports "cilium has been
upgraded" and does not restart the agent pod.

It installs in the same apply as everything else, including on a cluster that
has no CNI and no kube-proxy at all: there is nothing for it to wait on, because
the API server is a static pod on host networking and the cilium agent is
host-networked too. It is the one release with `wait: true`, so the apply blocks
until the agent DaemonSet is Ready and the nodes leave `NotReady`, and
kube-prometheus-stack declares `needs: cilium` because its install runs hook
Jobs, which cannot be scheduled before the CNI is up. Every other release simply
stays `Pending` until the CNI arrives, which is why only that one declares it.

A fresh cluster needs `cilium.serviceMonitors: false` until kube-prometheus-stack
is in: the chart will not render a ServiceMonitor before its CRDs exist. The same
flag is why `helmfile template -l name=cilium` fails offline whenever
`cilium.serviceMonitors` is true. Either use `helmfile diff -l name=cilium`
against the live cluster, or render with
`--state-values-set cilium.serviceMonitors=false`.

⚠️ Do not reach for `--skip-diff-validation-on-install` to get cilium past a
missing CRD. It turns off the API validation that also feeds
`.Capabilities.APIVersions`, which is exactly what the chart's ServiceMonitor
check reads — so with the flag on, a *new* cilium install fails to render even on
a cluster where `monitoring.coreos.com/v1` is present. `serviceMonitors: false`
is the answer on a fresh cluster; the flag is not.

## Storage

**The default is no storage at all.** `storage.persistence` is off, so
Prometheus, Alertmanager and Grafana run on emptyDir and the stack comes up on
a cluster with no storage backend. ⚠️ **A pod restart or reschedule loses
what it held**: Prometheus its metrics, Alertmanager its silences and
notification state (an alert already silenced or sent can fire again), Grafana
its sqlite — hand-saved dashboards, users, API keys, annotations. Dashboards
provisioned from ConfigMaps come back by themselves.

With `storage.persistence: true`, four PVCs ask for the class named by
`storage.className` — Prometheus, Alertmanager, Thanos Ruler and Grafana — and
that class has to exist with something behind it. Switching `storage.persistence`
works in both directions: turning it off leaves the PVCs in place, turning it
back on re-attaches the same claims.

### Three ways to get durable storage

- **Ceph (rook), what this repo ships.** Turn on `enabled.rookCeph`,
  `enabled.rookCephCluster`, `enabled.cephCsiDrivers` and
  `storage.persistence`, and fill in `ceph.nodes` with each node's name and
  its OSD device. It assumes **at least three nodes with a spare raw block
  device**: `mon.count` is 3 with `allowMultiplePerNode: false` and the pool
  is `replicated.size: 3` over `failureDomain: host`. The template refuses an
  *empty* `ceph.nodes`, but names that do not resolve install perfectly well
  and leave a CephCluster with zero OSDs that never converges — so check the
  names against `kubectl get nodes`.
- **Your own StorageClass.** Leave the ceph releases off, set
  `storage.className` to it and `storage.persistence: true`. On a single node
  that can be a `no-provisioner` local class over hand-made PVs
  (`volumeBindingMode: WaitForFirstConsumer`, one PV per PVC, pinned with
  `nodeAffinity`) — no replica and no dynamic provisioning, so every new PVC
  needs another PV by hand.
- **A single-node Ceph**, which needs four changes: `mon.count: 1`,
  `allowMultiplePerNode: true`, the pool at `replicated.size: 1` and
  `failureDomain: osd`. The vendored chart's own comment is the warning worth
  repeating — mons share a node only "for test environments where data loss is
  acceptable".

### When storage is on but does not work

The two ways it goes wrong look nothing alike, and neither says "storage":

- *The class object is missing.* Grafana's PVC sits `Pending` on
  `unbound immediate PersistentVolumeClaims`, but Prometheus and Alertmanager
  produce **no pod at all** — prometheus-operator looks the class up before it
  creates the StatefulSet, refuses, and writes
  `storage class "ceph-block" does not exist` into the Prometheus CR while
  helm still reports the release deployed -- nothing is Pending, so there is
  nothing to notice it by. A PV that merely carries the same
  `storageClassName` string does not satisfy that lookup. The release checks
  for the class before installing, so this fails at install time instead.
- *The class exists but nothing provisions.* The rook-ceph-cluster chart
  renders the `ceph-block` StorageClass itself, so it appears the moment that
  release installs — with or without a single OSD behind it. The PVCs then
  stay `Pending` and every one of those pods with them.

## Hooks: the things charts do not own

Five manifests are wired to the release they belong to, so a single apply leaves
the cluster complete rather than complete-except-for-a-kubectl-step.

| Hook | Release | Event | Flag |
| --- | --- | --- | --- |
| `kubectl apply -f observability/prom-stack/alerts/` | `kube-prometheus-stack` | postsync | `enabled.llmAlerts` |
| create `custom-dcgm-exporter-metrics` from `nvidia/custom-metrics.csv` | `gpu-operator` | presync | `enabled.dcgmCustomMetrics` |
| `kubectl apply -f nvidia/network-operator/nic-cluster-policy.yaml` | `network-operator` | postsync | `enabled.nicClusterPolicy` (**off**) |
| `kubectl apply -f scheduler/volcano/pdb.yaml` | `volcano` | postsync | `enabled.volcanoPdb` |
| `kubectl apply --server-side -k observability/prom-stack/dashboards/` | `kube-prometheus-stack` | postsync | `enabled.llmDashboards` |

Three more hooks are checks rather than manifests, and they fail the release
rather than fix anything: cilium's presync `kubectl get crd
gateways.gateway.networking.k8s.io` (only when `cilium.gatewayAPI`),
kube-prometheus-stack's presync `kubectl get storageclass <storage.className>`
(only when `storage.persistence`), and llm-slo's presync namespace create.

The DCGM one matters more than it looks: `nvidia/overrides.yaml` sets
`dcgmExporter.config.create: false` and names a ConfigMap the chart therefore
does not create. Without the hook, dcgm-exporter starts with no metric list. The
key has to be `dcgm-metrics.csv` — that is the filename the exporter is pointed
at.

`nicClusterPolicy` is off because a NicClusterPolicy is per-fabric hardware
config; applying this repo's copy on a cluster whose HCAs differ is worse than
not applying it at all.

The volcano one closes a real gap: the chart ships **no** PodDisruptionBudgets.
The budget that earns its place is `volcano-admission` — its `validatepodgroup`
webhook is `failurePolicy: Fail`, so draining both replicas stops every LWS in
the cluster from creating a PodGroup, and each group's own self-healing with it.
The objects carry their own `namespace: volcano-system`, which is why the hook
passes no `-n`.

## How the diff works

`helmDefaults.diffArgs` in `helmfile.yaml.gotmpl` sets `--three-way-merge`, so
every `helmfile diff` — and the diff `helmfile apply` runs before it syncs —
compares against **what is actually running**, not just against the previously
rendered manifest. That is what catches drift: a field somebody `kubectl edit`-ed
by hand shows up as a change instead of being silently ignored.

It is a helm-diff feature that helmfile passes through, so these are equivalent
if you ever need it ad hoc:

```bash
HELM_DIFF_THREE_WAY_MERGE=true helmfile diff
helmfile diff --diff-args "--three-way-merge"
```

Two things to know. `diffArgs` must be a list (a bare string fails to
unmarshal), and it only exists on `helmDefaults` — there is no per-release
`diffArgs`, so scoping it means `--diff-args` together with `-l`.

### What three-way merge actually compares

Worth knowing precisely, because it decides which drift you see. With
`--three-way-merge`, helm-diff (`manifest/generate.go`) does **not** diff two
manifests:

- **left side** = the object as it is **live in the cluster** (`helper.Get`,
  with `status` and metadata noise stripped) — not the manifest stored in the
  release secret;
- **right side** = the result of `CreateThreeWayMergePatch(old-release-manifest,
  newly-rendered-manifest, live-object)` replayed against the apiserver as a
  **server dry-run** (`helper.ServerDryRun = true`).

So the diff reads "what is running now → what the apiserver says it would
become". Consequences for a manual `kubectl edit` made between two revisions:

| The edited field is… | Shown in the diff? | Reverted by apply? |
| --- | --- | --- |
| declared by the chart | yes | yes — the patch sets it back |
| not declared by the chart at all | no | no — three-way merge preserves it by design |

Without `--three-way-merge` the live object is never fetched, so **neither case
shows up**. That is what turning it on buys.

### Hooks are not diffed

`diffArgs` carries only `--three-way-merge` today; `--no-hooks` sits beside it
commented out. It is worth knowing what it would stop, and why the noise below
is not drift. Chart hooks — `gpu-operator`'s `pre-upgrade` CRD-upgrade
Job and its RBAC, node-feature-discovery's `post-delete` prune, the
kube-prometheus-stack admission patch Jobs — carry
`helm.sh/hook-delete-policy: hook-succeeded`, so they are removed from the
cluster as soon as they finish, and helm does not keep them in the release's
stored manifest either. Diffing them therefore compares "rendered" against
"nothing" and reports every one as **added**, on every single run, no matter what
changed. Hundreds of lines of it, and none of it is drift.

The cost is real but small: a release whose *only* change is inside a hook now
diffs clean, and `helmfile apply` skips releases that diff clean — so a chart bump
that touches nothing but a hook Job would not be applied. In practice hook-only
changes come with a chart version bump that moves other objects too.

To look at hooks deliberately, override the list for one release — `--diff-args`
replaces `diffArgs` rather than appending to it, so re-state the three-way flag:

```bash
helmfile -l name=gpu-operator diff --diff-args "--three-way-merge"
```

`helmfile diff --no-hooks` and `helmfile apply --no-hooks` do the same thing from
the command line; `diffArgs` just makes it the default. Note that the helmfile
flag only affects the **diff** — the hooks themselves still run on apply.

### `--server-side` does not extend this

On Helm 4 `helm upgrade --server-side` defaults to `auto` (inheriting the
previous release's method), and server-side apply reconciles by `managedFields`
ownership rather than by merge patch. A `kubectl edit` that took ownership of a
chart-managed field can therefore fail the real apply with a field conflict that
the diff above never predicted — `helm upgrade --force-conflicts` is the escape
hatch.

Passing `--server-side` through helmfile does **not** close that gap. helm-diff
forwards the flag only to the render step, and both `helm template` and `helm
upgrade --dry-run` bail out before the apply where SSA is consulted — its
`serverSideFlags` helper says so in as many words: *"forwarded purely for
semantic correctness and so that helm-diff can be used as a drop-in wrapper
around `helm upgrade` with the same flags."* Treat it as flag compatibility, not
diff fidelity.

## The Gateway looks dead and is not

Three states that read as failure and are not, all met on real clusters.

**`Programmed: False`, reason `AddressNotAssigned`.** It means the cluster has
no LoadBalancer IPAM, so the Service keeps `EXTERNAL-IP <pending>` forever —
not that the listener is down. Cilium still programmes Envoy and traffic
arrives over the NodePort. The field to read instead is
`status.listeners[].attachedRoutes`: above zero means routes are attached.

```bash
kubectl get gateway -n llm-route openresty -o yaml | grep -A5 listeners:
```

**A 404 with an empty body.** The listener may be bound to a hostname, and a
request whose `Host` header is an IP matches no listener. Same URL with
`-H "Host: <the listener hostname>"` returns 200. `server: envoy` and
`x-envoy-upstream-service-time` in the response headers say Envoy handled it.

**HTTPRoutes rejected with `Accepted=False`, `NotAllowedByListeners`.** The
Gateway admits routes by namespace label, so `namespace-label.yaml` has to be
applied with the rest of `gateway-api/openresty/`. Nothing in the error names
the label.

## Air-gapped install

In [offline-install.md](offline-install.md): the bundle, and the two modes
(`registryMode: rewrite` and `mirror`). It is its own document because none of
it applies to a cluster that can reach the internet.

## Known gaps, deliberately left as-is

- **The ceph storage topology is per-cluster.** It now lives in `ceph:` in the
  environment file rather than in the values file, but it still has to be filled
  in: `ceph.nodes` names real Kubernetes nodes and real block devices, and
  `ceph.dashboardHost` is still the `example.internal` placeholder in
  `environments/default.yaml`. The template refuses to render an empty
  `ceph.nodes` rather than quietly producing a CephCluster with zero OSDs, so a
  cluster that inherits the base topology names nodes it does not have.
- **`enabled.cephCsiDrivers` is true, and arguably should not be.** rook-ceph
  v1.20 already pulls `ceph-csi-operator` in as a subchart
  (`csi.installCsiOperator`, default true) and creates the Driver CRs itself,
  so the separate release is a second owner of the same objects. It exists for
  taking driver lifecycle over by hand with `ceph/csi/values.yaml`. Left on
  because every cluster here installed it that way; switching it off is a
  change to make deliberately, with a diff.
- **The LLM gateway is pinned to one node, per cluster.** `bodylog` writes
  captured bodies to `llmGateway.hostPath` on `llmGateway.node` and
  `bodylog-exporter` ships them from that same path, so both are `nodeSelector`-ed
  to that one node. Set both keys per environment; the templates refuse to render
  with either empty rather than letting the pods schedule anywhere and capture
  nothing. An environment with no node to give them sets `enabled.bodylog` /
  `enabled.bodylogExporter: false` instead. Repointing them does not move the
  bodies already on the old node's disk.
- **`enabled.volcano: true` installs a second scheduler.** It is inert on its own —
  Volcano only schedules pods whose `spec.schedulerName` names it — but flipping
  it to `false` on a cluster that already runs Volcano makes the next apply
  **uninstall** it, and any pod still asking for that scheduler stops being
  schedulable. Adopting an install that helm does not own yet needs
  `helmfile -l name=volcano apply --take-ownership` once;
  `scheduler/volcano/README.md` has the whole switch-on order for LWS.
- **`descheduler` can evict `inference-prod` pods.** Read the header of
  `observability/descheduler/overrides.yaml` before touching its policy, and
  dry-run first:
  ```bash
  helmfile -f helmfile.yaml.gotmpl -l name=descheduler apply --set cmdOptions.dry-run=true
  ```
