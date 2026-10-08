# ModelSphere

<p align="center">
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-Apache%202.0-blue.svg"></a>
  <a href="https://github.com/modelsphere"><img alt="Repositories" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fapi.github.com%2Forgs%2Fmodelsphere&query=%24.public_repos&label=open%20source&suffix=%20repositories&color=blue"></a>
  <a href="docs/install.md"><img alt="Docs" src="https://img.shields.io/badge/docs-install%20guide-blue"></a>
</p>


## Overview

ModelSphere is an open-source LLM inference platform designed to make production-grade model serving simple, efficient, and continuously optimized. It provides instant deployment across heterogeneous accelerators, stays ready for the latest models through a flexible inference architecture, and continuously improves serving performance based on real-world workloads.

![features](docs/features.png)

## Highlights

- **Intelligent Auto Scaling.** Dynamically adjusts inference replicas and compute resources based on real-time service demand, while prioritizing resources for high-priority models to improve overall GPU utilization.
- **Quality-Aware Dynamic Throttling.** Goes beyond traditional RPM/TPM limits by dynamically controlling traffic based on real-time service metrics such as TTFT and output speed, maintaining service quality under changing workloads.
- **Advanced Serving Architecture.** Supports advanced inference architectures such as Prefill/Decode disaggregation and a unified L3 KV cache pool, enabling efficient cache sharing and higher resource utilization across serving instances.
- **Performance-Tuned Day-0 Deployment.** Rapidly supports newly released models with production-ready, performance-tuned deployment configurations optimized for real-world serving workloads. Please refer to our [model catalog](https://modelsphere.github.io/model-catalog/) for more information.
- **Broad Heterogeneous Accelerator Support.** Provides a unified serving stack across NVIDIA GPUs, Huawei Ascend, Iluvatar CoreX, and dozens of other AI accelerators, together with mainstream inference frameworks such as SGLang and vLLM.
- **Seamless In-Flight Generation Recovery.** When a serving pod fails mid-generation, ModelSphere transfers the in-flight request to a healthy pod and resumes generation from the interruption point, without restarting the request or disrupting the client stream ([read more](https://github.com/modelsphere/continuation_gateway)).
- **Workload-Driven AutoTune (preview version).** Uses real production workloads to automatically explore better serving configurations during idle compute periods ([read more](https://github.com/modelsphere/llm-autotune)).

## Quick start

### **Prerequisites**

1. a Kubernetes cluster, and `kubectl` pointing at it;
2. `helm`, `helmfile` and the `helm-diff` plugin.

### **Step 1: install the stack**

```bash
# 1. the stack itself, one pass
cp environments/private.yaml.example environments/mycluster.yaml   # edit it,
#    then add it under `environments:` in helmfile.yaml.gotmpl -- a values file
#    nothing registers is a file helmfile never reads:
#      mycluster:
#        values:
#          - environments/default.yaml
#          - environments/mycluster.yaml
make helm-apply ENV=mycluster
```

### **Step 2: deploy a model**

**Method 1: Using the command line**

```bash
helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm upgrade --install qwen modelsphere/sglang -n llm-demo --create-namespace \
  -f <your values.yaml>       # models/examples/sglang-qwen.yaml is a worked example
```

The model is served through the routing layer, at `http://openresty.llm-route.svc:8080/<release>/v1/chat/completions` -- the release name from step 2 is the path prefix (`qwen` above), and it is how the router picks the model.

**Method 2: Using the GUI platform**

Alternatively, you can use our GUI platform to deploy a model.

![image-20261008152111862](docs/model_catalog.png)

### **Step 3: test the service**

```bash
kubectl -n llm-route port-forward svc/openresty 8080:8080 &
curl http://127.0.0.1:8080/qwen/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",
       "messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

Exposing that outside the cluster is a Gateway, an Ingress or a Service of your choosing -- [the walkthrough](docs/install.md#7-gateway-objects) ships Gateway API objects for it.

## Architecture

![arch](docs/arch.png)


## Components

| Component | What it does | Repository |
|---|---|---|
| **Routing** | | |
| llm-openresty | Session-affinity router: pins a conversation to the backend that already holds its context | [llm-openresty](https://github.com/modelsphere/llm-openresty) |
| cache_aware_router (CART) | Routes each request to the replica holding the longest matching prefix | [cache_aware_router](https://github.com/modelsphere/cache_aware_router) |
| autoconfig | Operator that keeps the routing layer's config in step with the backends that exist | [autoconfig](https://github.com/modelsphere/autoconfig) |
| **Scaling and health** | | |
| llm-operator | Autoscales inference workloads on LLM-specific signals (KV-cache pressure, queue depth) | [llm-operator](https://github.com/modelsphere/llm-operator) |
| slo-scaler-decision-gen | Turns SLO targets and live signals into replica decisions | [slo-scaler-decision-gen](https://github.com/modelsphere/slo-scaler-decision-gen) |
| hang-watcher | Sidecar that restarts an engine which stopped making progress but still answers `/health` | [hang-watcher](https://github.com/modelsphere/hang-watcher) |
| **Observability** | | |
| bodylog, bodylog-exporter | Full request/response records from the router, and Prometheus metrics from them | [llm-openresty](https://github.com/modelsphere/llm-openresty) |
| **Engines** | | |
| sglang, vllm charts | The engine binaries are upstream; the charts are what makes them serve: shutdown that drains in-flight requests and then gets the GPUs released, hang-watcher wired to the liveness probe, the model's own CART, one instance spanning several nodes (LeaderWorkerSet), and the routing and scaling CRs that put the model on the router | [helm-charts](https://github.com/modelsphere/helm-charts) |
| **Portal** | | |
| console | ModelSphere community portal: identity (users, roles, login) and a federation gateway to Swiss and other backends | [console](https://github.com/modelsphere/console) |

## Documentation

| Document | What is in it |
|---|---|
| [`docs/install.md`](docs/install.md) | the complete install: preparing the machines, creating the Kubernetes cluster, and installing the stack on it -- with the air-gapped path and the detail on each step linked from there |
| [`docs/configuration.md`](docs/configuration.md) | what to change once it runs, and where: the cluster's environment file against a model's values file, with the guides for models, routing and rate limits, CART, autoscaling and rolling updates linked from there |
| [`docs/console.md`](docs/console.md) | opening the portal the first time: the address, the first login, and what the Model Serving pages need |

## Contributing

Please read the [Contributing Guide](CONTRIBUTING.md) — where a change belongs
(most of ModelSphere lives in the component repositories, not here), and what to
run before opening a pull request.

## License

Apache 2.0 -- see [LICENSE](./LICENSE).
