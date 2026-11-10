# test/e2e/gpu

End-to-end test of the product stack on an existing GPU cluster. `make test-e2e-gpu` does not create a cluster and does not delete one. It installs `part=others` with `helmfile -e gpu`, runs the specs, and uninstalls `part=others` again. `part=infra` (the CNI, Ceph, monitoring, the GPU and NIC operators, lws, volcano) is assumed to be already installed and is never selected.

## Infra and others

`helmfile.yaml.gotmpl` labels every release except `tier=model` with `part`. Model releases are what swissd deploys during the run; they are in neither set.

| part | tiers | why it is in that set |
|---|---|---|
| infra | cni | Uninstalling Cilium takes the cluster down. |
| infra | storage | Rook's CRDs and CephCluster. Uninstall is slow and deletes data. The gpu environment leaves Rook off and uses a StorageClass the cluster already has. |
| infra | observability | kube-prometheus-stack's CRDs, plus PrometheusRule and Grafana dashboard hooks that helm does not own. The GPU operator and the bodylog exporter need those CRDs. Descheduler is cluster policy; its overrides only evict nodes already tainted for a broken GPU. |
| infra | gpu | Drivers, device plugins and lws CRDs. Reinstalling gpu-operator drops `nvidia.com/gpu` off the nodes. The Ascend chart keeps its namespaces across an uninstall. |
| infra | scheduler | Volcano's CRDs and an admission webhook with `failurePolicy: Fail`. PodDisruptionBudgets are applied by a hook helm does not own. |
| others | llmgate, operator, portal | The product: openresty, bodylog and its exporters, autoconfig, llm-slo, llmscaleoperator, llm-canary-operator, swissd, console. LLMService CRDs belong to this set. `needs:` edges back to kube-prometheus-stack stay in the file and are not selected (`--skip-needs`). |
| (none) | model | Not installed by either target. |

`make helm-apply-infra`, `make helm-apply-others` and `make helm-destroy-others` ignore `SELECTOR`. helmfile ORs separate `-l` groups, so a caller selector must not be able to widen a destroy. There is no target that uninstalls `part=infra`.

`helmfile destroy` has no `--skip-needs`. The destroy target passes `-l part=others` and nothing else. The suite lists that selector as JSON before apply and before destroy, and refuses to continue if any selected release is not `part=others` or is a known infra name.

## Prerequisites

- A cluster that already has `part=infra` installed (`make helm-apply-infra ENV=gpu` once the placeholders below are filled in), with at least one node advertising allocatable `nvidia.com/gpu`.
- `KUBECONFIG` pointing at that cluster, or the current kubectl context. `E2E_KUBE_CONTEXT` selects one context. The suite copies it to a mode-0600 file and never prints it.
- kubectl, helm, helm-diff (`make helm-deps`), helmfile and Go.
- The chart repositories reachable from the machine that runs the suite. The cluster pulls engine images and model weights itself.
- GPU nodes holding the weights at the profile's `model.pathTemplate`. The default model is `Qwen/Qwen3-8B`, so the default path is `/mnt/disk0/models/Qwen/Qwen3-8B`.
- For CI: a self-hosted runner labelled so `.github/workflows/e2e-gpu.yaml` schedules on it, able to reach the cluster. That network is not part of this skeleton. The workflow is `workflow_dispatch` only until then.

## What a maintainer still has to fill in

`environments/gpu.yaml`, search for `REPLACE_ME`:

| Key | What it is |
|---|---|
| `cilium.clusterName` | This cluster's Cilium name. Must be unique if clusters ever peer. |
| `cilium.k8sServiceHost` | kubeadm `controlPlaneEndpoint`, or the control-plane node address. |
| `storage.className` | A StorageClass that already exists. bodylog-victorialogs claims it. |
| `llmGateway.node` | The node bodylog pins its sinks to. |

Also confirm, and change if the site differs:

- `llmGateway.hostPath` (default `/mnt/disk0/bodylog-sinks`).
- `cilium.podCIDR` if the cluster's podSubnet is not `192.168.0.0/16`. Changing it after Cilium is up renumbers every pod.
- `cilium.serviceMonitors` is false so the first infra apply can render before the Prometheus CRDs exist. After that apply, set it true and apply infra once more.
- `test/e2e/gpu/testdata/profile.yaml`: `model.pathTemplate`, and `nodes.gpuProductAliases` if the node's `nvidia.com/gpu.product` label is not `NVIDIA-A100-SXM4-80GB`. The alias is used only when `E2E_GPU_PRODUCTS` is set.
- The profile matches swiss 0.7.2 (`nodes.gpuProductAliases`). A newer swiss requires `nodes.gpus` and will reject this file until it is edited.
- `enabled.networkOperator` if the cluster has no RDMA devices (the default is on; `nicClusterPolicy` stays off).
- Runner labels in `.github/workflows/e2e-gpu.yaml` (`[self-hosted, gpu]` is a placeholder). `.github/actionlint.yaml` lists `gpu` so actionlint accepts it; change both when the label is confirmed.

No API key is committed. Openresty's chart default leaves auth off. Set `E2E_API_KEY` only if the cluster's openresty requires one, and do not put that key in the environment file in git.

## Covered

The releases the gpu environment installs (the same product set as `environments/default.yaml`; llm-canary-operator stays off) must be `deployed`, and every Deployment and StatefulSet in `console`, `llm-route`, `llm-scaler` and `llmscaleoperator-system` must finish rolling out. Then:

1. Log in to swissd with the `swissd-auth` Secret.
2. PUT `testdata/profile.yaml` (catalog URL from `E2E_CATALOG`) and require `/api/cluster` to report the profile name.
3. List the catalog and require `E2E_MODEL` and `E2E_VARIANT`.
4. Require a node with allocatable `nvidia.com/gpu` >= `E2E_GPU_COUNT`. This suite does not install infra to get one.
5. Plan and install the variant through swissd (`POST /api/plans`, `POST /api/install`), wait until the release and its ModelRoute are Ready.
6. Require the model pods to request and limit `nvidia.com/gpu`, and the node they landed on to advertise at least that many allocatable GPUs. The vllm chart sets the limit; admission copies it into the request.
7. `POST /v1/chat/completions` to the engine Service (port-forward) and to openresty at `/<release>/v1/chat/completions`. The model id sent is `E2E_SERVED_NAME` (`Qwen3-8B` for the default variant, not the catalog name `qwen3-8b`).
8. Uninstall through swissd and wait until no object named after the release remains.

`gpuProducts` is sent only when `E2E_GPU_PRODUCTS` is set. Unset, the variant's own `requires.gpus` still requests one GPU and no product is pinned. `forceGpuProducts` is sent only together with that list.

## Run

```sh
make helm-apply-infra ENV=gpu INTERACTIVE=false     # once, after filling gpu.yaml in
make test-e2e-gpu                                   # install others, test, uninstall others
make test-e2e-gpu KEEP_INSTALL=1                    # leave part=others installed
E2E_SKIP_INSTALL=1 make test-e2e-gpu                # specs only; does not uninstall either
make test-e2e-gpu E2E_VERBOSE=true
make test-e2e-gpu E2E_ARGS='-ginkgo.focus=catalog'
make helm-destroy-others ENV=gpu INTERACTIVE=false  # uninstall part=others by hand
```

`E2E_TIMEOUT` defaults to 45m for the kind suite and is left there. `make test-e2e-gpu` uses 210m unless `E2E_TIMEOUT` was set on the command line or in the environment.

`E2E_SKIP_INSTALL=1` skips both the install and the uninstall. A stack the suite did not install is not one it should remove. `KEEP_INSTALL=1` skips the uninstall after an install this suite did start. A failure before `helmfile apply` does not destroy anything.

| Variable | Default | Meaning |
|---|---|---|
| `KUBECONFIG` | kubectl's default | Cluster to use. Copied to a 0600 file for the run. |
| `E2E_KUBE_CONTEXT` | current context | Context to minify into that file. |
| `E2E_HELM_ENV` | `gpu` | Helmfile environment. |
| `E2E_CATALOG` | `https://modelsphere.github.io/model-catalog/` | Catalog base URL. schemaVersion v2 is in the profile. |
| `E2E_MODEL` | `qwen3-8b` | Catalog model name. |
| `E2E_VARIANT` | `vllm-tp1-a100` | Variant. 1 GPU, vendor nvidia, product `NVIDIA-A100-SXM4-80GB`. |
| `E2E_SERVED_NAME` | `Qwen3-8B` | OpenAI model id the engine serves. |
| `E2E_RELEASE` | `e2e-gpu` | Helm release name and openresty route. |
| `E2E_NAMESPACE` | `llm-demo` | Namespace swissd creates. |
| `E2E_BACKEND` | `helm` | `applyWith`: `helm` or `llmsvc`. |
| `E2E_GPU_PRODUCTS` | empty | Comma-separated products sent as `gpuProducts`. Empty sends nothing. |
| `E2E_FORCE_GPU_PRODUCTS` | false | Send `forceGpuProducts: true` when a product list is set. |
| `E2E_GPU_COUNT` | `1` | GPUs the pod must request and the node must advertise. |
| `E2E_ENGINE_SERVICE` | the release name | Engine Service to port-forward. |
| `E2E_ENGINE_PORT` | `8000` | Engine Service port. |
| `E2E_API_KEY` | empty | Sent as `Authorization: Bearer` to openresty when set. |
| `E2E_INSTALL_TIMEOUT` | `30m` | helmfile apply and destroy. |
| `E2E_READY_TIMEOUT` | `15m` | Workload rollout after install. |
| `E2E_MODEL_TIMEOUT` | `90m` | Release ready, including the weight download. |
| `E2E_GONE_TIMEOUT` | `30m` | Uninstall. The variant's grace period is 1200s. |
| `E2E_CHAT_TIMEOUT` | `3m` | One chat call. |
| `E2E_VERBOSE` | false | Print helm releases, pods and chat bodies. |
| `KEEP_INSTALL` | false | Do not uninstall `part=others` afterwards. |
| `E2E_SKIP_INSTALL` | false | Do not install or uninstall `part=others`. |

Durations accept a Go duration (`90m`) or a bare number of seconds.

`helmfile -e gpu -l part=others template` renders without a cluster. `part=infra` does not: Cilium's ServiceMonitors and several charts want CRDs or a live API, which is why `cilium.serviceMonitors` starts false. `llmGateway.node` and `hostPath` have to be non-empty for the others set to render at all; `REPLACE_ME` is enough for a template and not enough for an apply.
