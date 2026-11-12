# Serving a model with containers, without Kubernetes

One model, on a set of machines, with nothing but a container runtime and SSH. The
routing layer runs as `docker compose` on a control machine; each accelerator machine
runs one engine container.

```
                      control machine (no accelerator needed)
                      ┌───────────────────────────────────────┐
  client ── :8080 ──► │ openresty   one port, limits, records │
                      │     │                                 │
                      │     ▼                                 │
                      │ cart        cache-aware routing       │
                      └─────┬─────────────────────────────────┘
          ┌─────────────────┼──────────────────┐
          ▼                 ▼                  ▼
       machine           machine            machine      ← one engine container each
```

Two files are the whole input: `.env` (the model, the engine, the hardware, the
limits) and `hosts` (the machines). `render.sh` turns them into the route openresty
serves, the cache-aware router's worker list, and one launch script per machine, so
the route's backends and the engines' own addresses cannot drift apart.

The full guide is [docs/docker-compose.md](../docs/docker-compose.md). This page is
the prerequisites and the commands.

## Prerequisites

Nothing here installs any of this, and most of it fails in a way that looks like a
hung engine rather than a missing dependency. Check it before the first run.

### Control machine

Where you run `./up.sh`. It needs no accelerator, and it may be one of the engine
machines.

| Requirement | How to check |
|---|---|
| Docker with the compose plugin | `docker compose version` |
| **Passwordless SSH to every engine machine** as `SSH_USER` (default `root`) | `ssh -o BatchMode=yes root@<machine> true` — must succeed without a prompt for every line in `hosts`. `up.sh` visits the machines one at a time and cannot answer a password |
| Network reach to each engine machine's `ENGINE_PORT` | `curl -m 5 http://<machine>:8050/v1/models`, once an engine is running |
| **`GATEWAY_PORT` and `CART_PORT` free.** The routing containers use host networking, so they bind here directly; `up.sh` checks both before starting and names whatever holds one | `ss -ltn \| grep -E ':(8080\|8071) '` |
| Able to pull the routing images | `docker pull $OPENRESTY_IMAGE` |

### Engine machines

| Requirement | How to check |
|---|---|
| A container CLI: Docker, or nerdctl where there is no Docker daemon (`CTR_CLI`) | `docker version` / `nerdctl version` |
| **The accelerator driver, installed and healthy on the host** | NVIDIA: `nvidia-smi`. Ascend: `npu-smi info`. The container image does not carry a driver |
| **The container runtime integration for that accelerator** | NVIDIA: `nvidia-container-toolkit`, so `--gpus` works. Ascend: the vendor OCI runtime, or the device mounts the example lists in its place. Without it the container starts with no accelerator inside and the engine fails on its first allocation |
| The engine image, pullable or already present | `docker image inspect $ENGINE_IMAGE` |
| **The weights on local disk, one copy per machine** | `ls $MODEL_PATH` — there is no shared-storage path here |
| `ENGINE_PORT` free | `ss -ltn \| grep :8050` |

### Additionally, for an instance that spans machines

Only when `NODES_PER_INSTANCE` is greater than 1. Every item here fails silently: the
model loads, and then the engine hangs at its first collective operation.

| Requirement | How to check |
|---|---|
| **RDMA/InfiniBand ready**, if you intend to use it: ports up, devices present | `ibstat` (every port `Active`), `ls /dev/infiniband`, and the device named in `DOCKER_FLAGS` |
| **The collective interface named explicitly** | `-e NCCL_SOCKET_IFNAME=<nic>` or `-e HCCL_SOCKET_IFNAME=<nic>` in `DOCKER_FLAGS`. Left unset on a machine with several interfaces, the engine picks one that cannot reach its peer |
| **`DIST_PORT` free on every machine of the instance, and reachable between them** | `ss -ltn \| grep :29500` |

## Quick start

```bash
cp examples/ascend-glm53-flash.env .env   # ls examples/ for the others
cp hosts.example hosts                    # your machines, one address per line
```

`examples/` holds complete starting points, one per hardware and model that has been
run — copy the closest one rather than filling in a blank template.

In `.env`, the minimum to change is at the top: `MODEL_PATH` (where the weights are
on each machine), `MODEL_NAME` (what clients send) and `ROUTE` (the first segment of
the URL). If the engine is not to take a whole machine, change `TP` and
`DEVICES_PER_NODE` together, and name the cards in `DOCKER_FLAGS`.

```bash
./up.sh            # render, start the engine on every machine, start the routing layer
```

The engine is started before the routing layer and `up.sh` waits for it to serve
`/v1/models`, because a container starts in seconds while weights load for minutes.

```bash
curl -s http://127.0.0.1:8080/<route>/_health_status
curl http://127.0.0.1:8080/<route>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<MODEL_NAME>","messages":[{"role":"user","content":"hello"}],"max_tokens":16}'
```

The first path segment is `ROUTE`, not the model name. The gateway is on
`GATEWAY_PORT` of this machine's own address and answers any machine that can route
to it, so put
authentication (`API_KEYS_DIR`) or your own proxy in front of it on a shared network
-- and note that the `/<route>/_*` status endpoints have no authentication in any
case, and name the engines.

## Configuration

Everything is in `.env`, whose sections are ordered by how likely you are to change
them, and `hosts`, which is one machine per line (a second column only where SSH and
the data network are different addresses). Both are gitignored, since they hold your
addresses; `.env` keeps that name because docker compose reads it directly.

| Section of `.env` | Holds |
|---|---|
| the model | what you are serving, and where its weights are — always needs editing |
| the shape | how the machines in `hosts` add up to instances (`NODES_PER_INSTANCE`, `TP`, `PP`) |
| the engine | engine, image, flags. Comes with the hardware and the model; the example has it |
| the accelerators | `DOCKER_FLAGS` — devices, environment, a vendor runtime — and `PRE_START` |
| limits and access | rate limits, authentication, request records. Tune after measuring |
| plumbing | CART's port, registries, the container CLI, SSH. Rarely touched |

Applying a change is not the same cost everywhere:

| Change | Apply with | In-flight requests |
|---|---|---|
| Limits, the machine list, the route name | `SKIP_ENGINES=1 ./up.sh` | kept — openresty reloads gracefully |
| Engine flags, `TP`/`PP`, the image | `./down.sh && ./up.sh` | cut — the engine restarts |
| Stop everything | `./down.sh` | — |
| Stop the engines, keep the gateway up | `KEEP_ROUTER=1 ./down.sh` | the route answers 503 until they return |

`generated/` is output, never input: it is rewritten from `.env` and `hosts` on every
run, and the files openresty and the router read are overwritten in place rather than
replaced, because a container holds the file it was started with. Do not delete that
directory while the stack is running — the host would then show the new configuration
while the container served the old, or nothing at all.
