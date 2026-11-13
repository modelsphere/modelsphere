# Serving a model with containers, without Kubernetes

One model, on a set of GPU servers, with nothing but a container runtime and SSH. The
routing layer runs as `docker compose` on a control machine; each GPU server runs one
engine container. Use it where there is no cluster — a handful of servers, a proof of
concept, an air-gapped rack.

```
                                 control machine (no accelerator needed)
                                ┌───────────────────────────────────────────────┐
  client ── :GATEWAY_PORT ────► │ openresty   gateway: authentication,          │
            (default 8080)      │             rate limits                       │
                                │     │                                         │
                                │     ▼                                         │
                                │ cart        cache-aware routing               │
                                └─────┬─────────────────────────────────────────┘
                 ┌────────────────────┼─────────────────────┐
                 ▼                    ▼                     ▼
            GPU server           GPU server            GPU server   ← one engine container each
```

Two files configure a deployment:

- `.env` — the model, the engine, the hardware and the limits
- `hosts` — the GPU servers, one per line

## Prerequisites

The deployment scripts do not install or configure any of the following. Verify each
item before the first deployment: a missing prerequisite usually shows up as an engine
that starts but never becomes ready, not as an explicit error.

In the checks below, `<NAME>` stands for that setting's value in `.env`, which lives
on the control machine; substitute it by hand when running a check on a GPU
server.

### Control machine

Where you run `./up.sh`. It needs no accelerator, and it may be one of the engine
GPU servers.

| Requirement | How to check |
|---|---|
| Docker with the compose plugin | `docker compose version` |
| **Passwordless SSH to every GPU server** as `SSH_USER` (default `root`) | `ssh -o BatchMode=yes root@<gpu-server> true` — must succeed without a prompt for every line in `hosts`. `up.sh` visits the GPU servers one at a time and cannot answer a password. Not needed for the control machine itself: a `hosts` line of `127.0.0.1` or one of its own addresses runs locally, so a single-server deployment needs no SSH at all |
| Network reach to each GPU server's `ENGINE_PORT` | `curl -m 5 http://<gpu-server>:<ENGINE_PORT>/v1/models`, once an engine is running |
| **`GATEWAY_PORT` and `CART_PORT` free.** The routing containers use host networking, so they bind here directly; `up.sh` checks both before starting and names whatever holds one | `ss -ltn \| grep -E ':(<GATEWAY_PORT>\|<CART_PORT>) '` |
| Able to pull the routing images | `docker pull <OPENRESTY_IMAGE>` |

### GPU servers

| Requirement | How to check |
|---|---|
| A container CLI: Docker, or nerdctl where there is no Docker daemon (`CTR_CLI`) | `docker version` / `nerdctl version` |
| **The accelerator driver, installed and healthy on the host** | NVIDIA: `nvidia-smi`. Ascend: `npu-smi info`. The container image does not carry a driver |
| **The container runtime integration for that accelerator** | NVIDIA: `nvidia-container-toolkit`, so `--gpus` works. Ascend: the vendor OCI runtime, or the device mounts the example lists in its place. Without it the container starts with no accelerator inside and the engine fails on its first allocation |
| The engine image, pullable or already present | `docker image inspect <ENGINE_IMAGE>` |
| **The weights on local disk, one copy per GPU server** | `ls <MODEL_PATH>` — there is no shared-storage path here |
| `ENGINE_PORT` free | `ss -ltn \| grep :<ENGINE_PORT>` |

### Additionally, for an instance that spans GPU servers

Only when `NODES_PER_INSTANCE` is greater than 1. Every item here fails silently: the
model loads, and then the engine hangs at its first collective operation.

| Requirement | How to check |
|---|---|
| **RDMA/InfiniBand ready**, if you intend to use it: ports up, devices present | `ibstat` (every port `Active`), `ls /dev/infiniband`, and the device named in `DOCKER_FLAGS` |
| **The collective interface named explicitly** | `-e NCCL_SOCKET_IFNAME=<nic>` or `-e HCCL_SOCKET_IFNAME=<nic>` in `DOCKER_FLAGS`. Left unset on a GPU server with several interfaces, the engine picks one that cannot reach its peer |
| **`DIST_PORT` free on every GPU server of the instance, and reachable between them** | `ss -ltn \| grep :<DIST_PORT>` |

## Quick start

```bash
cd docker
cp examples/ascend-glm53-flash.env .env   # ls examples/ for the others
cp hosts.example hosts                    # this GPU server; edit it for several
# set MODEL_PATH (and MODEL_NAME, ROUTE) at the top of .env, then:
./up.sh
```

`examples/` holds complete, tested starting points, one per hardware and model — copy
the closest one rather than filling in a blank template. `up.sh` renders first, then
starts the engine on every GPU server, waits until each serves `/v1/models` (a container
starts in seconds, the weights load for minutes), then starts the routing layer. To
see what would run without running it: `./render.sh`, then read `generated/`.

```bash
curl -s http://127.0.0.1:8080/<ROUTE>/_health_status
curl http://127.0.0.1:8080/<ROUTE>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<MODEL_NAME>","messages":[{"role":"user","content":"hello"}],"max_tokens":16}'
```

The first path segment is `ROUTE`, not the model name. `./down.sh` stops everything.

## Configuration

`.env` holds everything, in sections ordered by how likely you are to change them;
`hosts` is one GPU server per line (a second column only where SSH and the data network
use different addresses). Both are gitignored. `generated/` is output, rewritten on
every run — never edit it, and do not delete it while the stack runs: openresty and
CART read files from it in place.

| Section of `.env` | Holds |
|---|---|
| the model | what you are serving, and where its weights are — always needs editing |
| the shape | how the GPU servers in `hosts` add up to instances (`NODES_PER_INSTANCE`, `TP`, `PP`) |
| the engine | engine, image, flags — comes with the example |
| the accelerators | `DOCKER_FLAGS` (devices, environment, a vendor runtime) and `PRE_START` |
| limits and access | rate limits and authentication — tune after measuring |
| plumbing | ports, images, the container CLI, SSH — rarely touched |

### How many instances

| `NODES_PER_INSTANCE` | Four 8-card GPU servers give | Use it when |
|---|---|---|
| `1` (default) | four instances of 8 cards, balanced by CART | the weights fit in one GPU server: more throughput, no cross-GPU server collectives, a failure costs one instance |
| `4` | one instance of 32 cards | the weights do not fit in one GPU server |

GPU servers are taken in file order; the first GPU server of each instance is rank 0, the
only one that serves the API. `render.sh` refuses a shape where `TP × PP` does not equal
`DEVICES_PER_NODE × NODES_PER_INSTANCE`, or where the server count does not divide.
An instance spanning GPU servers also needs the collective interface named in
`DOCKER_FLAGS` (see Prerequisites), and is restarted as a whole — the containers run
with `--restart no`, because a lone rank coming back waits at a rendezvous forever.

### Different hardware

There is no vendor-specific code; the hardware is three variables:

| Variable | What it is |
|---|---|
| `ENGINE_IMAGE` | the engine build for this hardware |
| `DOCKER_FLAGS` | every extra container argument, verbatim: devices, `-e`, mounts, a vendor runtime. `{HOST}` is replaced with the GPU server's own address |
| `PRE_START` | anything that must run inside the container before the engine |

`--network host --ipc=host`, the memlock/stack ulimits, the weights mount and a cache
directory are always added. Keep `DOCKER_FLAGS` on one line. Things that differ from
Kubernetes:

- **Nothing injects the devices.** No device plugin here: the runtime or device mounts
  must be asked for in `DOCKER_FLAGS`. For Ascend, docker takes the runtime's
  registered **name** (`--runtime ascend`, from `/etc/docker/daemon.json`), not a path.
- **No CPU or memory limit** unless you add `--cpus` / `--memory` — relevant when
  comparing throughput with a Kubernetes deployment, which normally has both.
- **Ascend's driver is mounted at start**, so `PRE_START` runs `ldconfig` for it.

Mixing hardware in one deployment is not supported (the route's latency limits are
judged across all instances); run a second deployment with its own `ROUTE`.

The engine command is built from `ENGINE`, the port and `TP`/`PP`;
`ENGINE_EXTRA_ARGS` is appended verbatim (a JSON value needs its own single quotes),
and `ENGINE_CMD` replaces the whole command for an image that starts its own way, with
`{HOST} {BIND} {PORT} {RANK} {NNODES} {LEADER} {DIST_PORT} {MODEL_NAME} {TP} {PP}`
substituted per GPU server. The flags the rate limiter depends on (`--enable-metrics`,
`--enable-cache-report`, `--stream-response-default-include-usage` on SGLang,
`--enable-prompt-tokens-details` on vLLM) are always added — with `ENGINE_CMD`, add
them yourself.

### Limits and applying changes

`MAX_CONCURRENCY` (per instance), `TTFT_LIMIT_MS`, `TPS_LIMIT_TPS`, `ADAPTIVE_CC` and
`ADAPTIVE_CC_MIN_FRAC` are the gateway's limits; `CART_MAX_LOAD` and
`CART_MAX_BODY_SIZE` are CART's. Over a limit is an immediate `429` with
`Retry-After: 1` — nothing is queued.

Re-running `./up.sh` applies any change: engines whose rendered spec is unchanged and
still running are kept, openresty reloads gracefully, and CART is signalled to re-read
its worker list.

| Change | In-flight requests |
|---|---|
| Limits, route name, adding or removing GPU servers | kept — only new GPU servers start, removed ones need `docker rm -f engine-<ROUTE>` on that GPU server |
| Engine flags, `TP`/`PP`, image | cut on the GPU servers whose engine changed — those are recreated |
| Any CART field other than its workers | restart CART: `docker compose restart cart` |
| Force every engine to restart | `FORCE_ENGINES=1 ./up.sh` |

### Authentication

Off by default: with no key file every request is let through and `_health_status`
reports `api_keys_configured=false`. To turn it on:

```bash
mkdir -p keys && echo 'sk-one:team-a,sk-two:team-b' > keys/keys
# .env:  API_KEYS_DIR=./keys
docker compose up -d && docker compose exec openresty openresty -s reload
```

Keys are reloaded without a restart, so a new key can be added beside the old one
before the old one is removed. The `/<ROUTE>/_*` status endpoints are never
authenticated.

## Troubleshooting

```bash
curl -s http://127.0.0.1:8080/<ROUTE>/_health_status   # each peer: active or banned
curl -s http://127.0.0.1:8080/<ROUTE>/_tps_status      # decode rate, adaptive limit
curl -s http://127.0.0.1:8080/<ROUTE>/_429_status      # rejections by reason
```

| Symptom | Check |
|---|---|
| `502` on the route | the first path segment is not `ROUTE` |
| `503` | every peer failed its health check: `_health_status`, then `docker logs engine-<ROUTE>` on the GPU server |
| `429` at low load | adaptive concurrency at its floor: `_tps_status`, and whether `TPS_LIMIT_TPS` is reachable on this hardware |
| An instance never becomes ready | `docker logs engine-<ROUTE>` on rank 0, and on every rank of a multi-server instance |
| Which instance served a request | set `EXPOSE_ROUTED_PEER=true` and re-run `./up.sh`: responses then carry `X-Routed-Peer` |

## Not provided

Compared with the Kubernetes deployment: nothing restarts a failed instance, there is
no autoscaling, no backend discovery (`hosts` is the truth), no rolling update, and one
model per deployment — a second model is a second copy of `docker/` with its own
`ROUTE`, ports and GPU servers.
