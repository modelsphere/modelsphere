# test/e2e/kind

End-to-end test of the stack on a CPU-only kind cluster. `make test-e2e-kind`:

1. creates kind cluster `modelsphere-e2e` from `kind-config.yaml` (skipped if it exists);
2. installs the stack with `helmfile -e kind apply` (`environments/kind.yaml`);
3. waits for every workload in `console`, `llm-route`, `llm-scaler` and
   `llmscaleoperator-system`, then runs the Ginkgo specs;
4. deletes the cluster on success. A failure leaves it up for a look.

The `kind` environment turns off everything that needs GPUs, NICs, ceph disks or
the Prometheus operator, and shrinks openresty to one small replica. The whole
stack then requests about 2.5 CPU / 3 GiB and fits a 4 vCPU / 16 GB GitHub runner.
swissd is installed at cluster scope (the default `swiss.rbacScope: cluster`), and it creates
the model namespace (`llm-demo`) on the first install.

## Profiles

`KIND_PROFILE` picks how the cluster is networked; the stack and the specs are
the same. The `e2e-kind` workflow runs both.

| Profile | Kind config | Helmfile environment | Networking |
|---|---|---|---|
| `default` | `kind-config.yaml` | `kind` | kind's own CNI (kindnet) and kube-proxy (iptables, or `KIND_PROXY_MODE`) |
| `cilium` | `kind-cilium-config.yaml` | `kind-cilium` | no default CNI and `kubeProxyMode: none`; the helmfile's cilium release with `kubeProxyReplacement: true`, so Services go through cilium's eBPF datapath |

In the `cilium` profile the node stays NotReady until cilium is up. The cilium
release is the one release helmfile waits for, so the rest of the stack still
installs in a single `helmfile -e kind-cilium apply`. Without kube-proxy the
agent reaches the apiserver at `<cluster>-control-plane:6443`, which the suite
sets from `KIND_CLUSTER`. Cilium needs the `vxlan` kernel module (its tunnel
device); GitHub's runners have it.

## Covered

28 specs in `default`, 31 in `cilium`. Every release the environment installs
must be `deployed` and its workloads ready; beyond that:

| Component | Status | Notes |
|---|---|---|
| swissd | tested | `/healthz`, `/readyz`, login, site profile, `mock-llm` in the catalog; plans, installs and uninstalls the model with both backends (`helm`, `llmsvc`) at cluster scope, creating `llm-demo` |
| console | tested | OAuth password login as the default admin |
| openresty | tested | on a third mock release: `/v1/models`; `/v1/chat/completions`, `/v1/completions` and `/v1/messages`, each streamed and not; 401 for a missing or wrong API key (the kind env sets a test key, `sk-e2e-kind`); 16 concurrent requests; 429 once the ModelRoute's peers are patched to `maxConcurrency: 1`. Also a chat for each backend. One small replica |
| autoconfig | tested | the model's ModelRoute turns Ready and openresty serves its route; a ModelRoute change reaches openresty (the 429 spec) |
| bodylog, bodylog-victorialogs | tested | the chat request (by nonce and model) is found in victorialogs |
| llmscaleoperator | tested | its LLMService CRD is available to swissd; the `llmsvc` backend deploys through it |
| bodylog-exporter | installed only | ServiceMonitor off |
| llm-slo | installed only | no scaling decision is checked |
| kube-prometheus-stack, alerts, dashboards, alert-webhook | off | no ServiceMonitors |
| rook-ceph, rook-ceph-cluster, ceph-csi-drivers | off | kind's `standard` local-path storage, no persistence |
| gpu-operator, dcgm metrics, network-operator, NicClusterPolicy, ascend-device-plugin | off | CPU-only node |
| cilium | tested (`cilium` profile) / off (`default`) | release deployed, agent DaemonSet rolled out, no kube-proxy DaemonSet, `cilium-dbg status` reports `KubeProxyReplacement: True`; in-cluster Service traffic (e.g. swissd and the operators reaching the apiserver's ClusterIP, every DNS lookup through the kube-dns Service) goes through it. Hubble relay is installed; Hubble and network policy are not checked |
| lws, volcano, descheduler, node-problem-detector, condition2taint, llm-canary-operator | off | |

Not covered either: real GPUs and real engines (the model is `mock-llm`, no
weights), autoscaling, CART, and the helmfile `models:` path.

## Run

Needs docker, kind, kubectl, helm with helm-diff (`make helm-deps`), helmfile and Go.

```sh
make test-e2e-kind                          # create, install, test, delete
make test-e2e-kind KEEP_CLUSTER=1           # keep the cluster afterwards
make test-e2e-kind E2E_ARGS='-ginkgo.focus=llmsvc'
E2E_SKIP_INSTALL=1 make test-e2e-kind       # reuse an installed cluster, specs only
make test-e2e-kind KIND_PROXY_MODE=nftables # kernel without xt_statistic
make test-e2e-kind KIND_PROFILE=cilium      # cilium instead of kindnet and kube-proxy
make test-e2e-kind E2E_VERBOSE=true         # print core step outputs
make cleanup-test-e2e-kind
```

`E2E_VERBOSE=true` (off by default, on in CI) prints the output of the core
steps as they pass: `helm list -A` and `kubectl get pods -A` after install,
`cilium-dbg status` in the cilium profile, each model's LLMService,
ModelRoute (with its status) and pods, and the openresty answers (status and
the first 400 bytes of the body). A failing spec dumps the cluster state either
way.

Images are pulled by the cluster from Docker Hub and ghcr.io, so a cold run
spends most of its time there.
