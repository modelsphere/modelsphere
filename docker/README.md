# ModelSphere without Kubernetes

One model, served on a set of machines, with containers.

## 0. The machines have to be ready first

None of this is installed for you, and most of it fails in a way that looks like a
hung engine rather than a missing dependency. Check it before the first run.

**The control machine** -- where you run `./up.sh`; it needs no accelerator, and it
may be one of the engine machines:

| | Check |
|---|---|
| docker with the compose plugin | `docker compose version` |
| **passwordless SSH to every engine machine** as `SSH_USER` (default root) | `ssh -o BatchMode=yes root@<machine> true` -- must succeed with no prompt, for every line in `hosts`. `up.sh` runs them one at a time and cannot answer a password |
| can reach each engine machine's `ENGINE_PORT` | `curl -m 5 http://<machine>:8050/v1/models` once an engine is up |
| `GATEWAY_PORT` free, and `NET_SUBNET` not already routed | `ss -ltn \| grep :8080` / `ip -4 route \| grep 172.31.` and `docker network inspect` the existing ones. A compose network that overlaps a real one breaks whatever used that range |
| can pull the routing images | `docker pull $OPENRESTY_IMAGE` |

**Every engine machine:**

| | Check |
|---|---|
| a container CLI -- docker, or nerdctl where there is no Docker daemon (`CTR_CLI`) | `docker version` / `nerdctl version` |
| **the accelerator driver, installed and healthy on the host** | NVIDIA: `nvidia-smi`. Ascend: `npu-smi info`. The container does not carry a driver |
| **the container runtime hook for that accelerator** | NVIDIA: `nvidia-container-toolkit`, so `--gpus` works. Ascend: the vendor OCI runtime, or the device mounts the example lists instead. Without it the container starts with no accelerator in it and the engine fails on its first allocation |
| the engine image, pullable or already present | `docker image inspect $ENGINE_IMAGE` |
| **the weights on local disk, one copy per machine** | `ls $MODEL_PATH` -- there is no shared-storage path here |
| `ENGINE_PORT` free | `ss -ltn \| grep :8050` |

**Only for a multi-machine instance** (`NODES_PER_INSTANCE` > 1) -- all three of these
fail silently, with the model loading and then hanging at its first collective:

| | Check |
|---|---|
| **RDMA/InfiniBand ready**, if you want it: ports up and the devices present | `ibstat` (every port `Active`), `ls /dev/infiniband` |
| the collective interface **named** in `DOCKER_FLAGS` | `-e NCCL_SOCKET_IFNAME=<nic>` / `-e HCCL_SOCKET_IFNAME=<nic>`. Left unset on a machine with several interfaces, the engine picks one that cannot reach its peer |
| `DIST_PORT` free on every machine of the instance, and reachable between them | `ss -ltn \| grep :29500` |

On NVIDIA there are two further host-level prerequisites that only bite across
machines, both measured, both looking like a hang rather than an error: **PCIe ACS
must be off** on every bridge (otherwise NCCL deadlocks during initialisation
whenever GDR is on, and it comes back after each reboot), and **nvidia-peermem must
stay loaded** (it unloads itself on a long-running machine, and then any container
restart hangs). `examples/nvidia-qwen.env` has the detail and the commands.

## 1. Two files

```bash
cp examples/ascend-glm53-flash.env .env   # ls examples/ for the others
cp hosts.example hosts                    # your machines, one address per line
```

`.env` keeps that name because docker compose loads it by itself; the examples are
visible files so you can see what there is to copy. Edit `.env` from the top -- its
sections run from "you have to set this" (the model, the weights path) down to
"leave it alone" (registries, the compose network).

## 2. Start it

```bash
./up.sh            # renders, starts the engine on every machine, starts the router
```

`./render.sh` alone renders into `generated/` and applies nothing -- that is how you
read the exact route config and the exact per-machine container command before
anything runs. `./down.sh` stops everything.

The guide is [docs/docker-compose.md](../docs/docker-compose.md): how many instances
the machines add up to, NVIDIA and Ascend, rate limiting, authentication, and what
this path does not do that Kubernetes does.
