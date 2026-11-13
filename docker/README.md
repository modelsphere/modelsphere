# Serving a model with Docker

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

Where you run `./up.sh`. It needs no accelerator, and it may be one of the GPU servers.

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

These apply only when `NODES_PER_INSTANCE` is greater than 1, i.e. one model instance
runs across several GPU servers. If any of them is not met, the engine usually loads
the model and then stops responding when the servers first communicate, without an
error message pointing to the cause.

| Requirement | How to check |
|---|---|
| **RDMA/InfiniBand ready**, if you intend to use it: ports up, devices present | `ibstat` (every port `Active`), `ls /dev/infiniband`, and the device named in `DOCKER_FLAGS` |
| **The network interface the servers connect over, named explicitly** | `-e NCCL_SOCKET_IFNAME=<nic>` (NVIDIA) or `-e HCCL_SOCKET_IFNAME=<nic>` (Ascend) in `DOCKER_FLAGS`. The servers of an instance first find and connect to each other over this host interface. Without it, on a server with several network interfaces the engine chooses one automatically, and may choose one the other servers cannot reach (a container bridge, or a network without a route between the servers); the instance then never finishes connecting. On Ascend this is only the connection setup — the collective traffic itself runs over the NPUs' own RoCE ports, configured in `/etc/hccn.conf` |
| **`DIST_PORT` free on every GPU server of the instance, and reachable between them** | `ss -ltn \| grep :<DIST_PORT>` |

## Quick start

```bash
cd docker
cp examples/glm-5.3-flash-910b4.env .env   # ls examples/ for the others
cp hosts.example hosts                    # this GPU server; edit it for several
# set MODEL_PATH (and MODEL_NAME) at the top of .env, then:
./up.sh
```

`examples/` holds complete, tested starting points, one per hardware and model — copy
the closest one rather than filling in a blank template. `up.sh` first generates the
routing configuration and the launch commands from `.env` and `hosts`, then starts the
engine on every GPU server, waits until each serves `/v1/models` (a container
starts in seconds, the weights load for minutes), then starts the routing layer.

`up.sh` returns once every instance serves (up to 90 minutes) and prints the service,
for example:

```
=== model service
  endpoint   http://10.0.0.21:8080/glm-5.3-flash/v1        (OpenAI-compatible)
  model      glm-5.3-flash
  instances  1 of 1 ready
  try        curl http://10.0.0.21:8080/glm-5.3-flash/v1/chat/completions -H 'Content-Type: application/json' \
               -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hello"}]}'
```

| Command | What it does |
|---|---|
| `./up.sh` | Starts everything; returns once every instance serves |
| `./up.sh --no-wait` | Starts everything and returns at once |
| `./status.sh` | Shows each instance (serving, loading, stopped), the routing layer and the endpoint; exits 0 once everything serves |
| `./down.sh` | Stops everything |

## Configuration

| File | What it is |
|---|---|
| `.env` | All settings. Gitignored |
| `hosts` | The GPU servers, one per line; a second column only where SSH and the data network use different addresses. Gitignored |
| `keys/` | API keys (see Authentication). Gitignored |
| `generated/` | Generated from `.env` and `hosts` on every run. Do not edit it, and do not delete it while the stack runs — openresty and CART read their configuration from it. `./render.sh` generates it without starting anything, to see exactly what would run |

| Section of `.env` | Holds |
|---|---|
| the model | what you are serving, and where its weights are — always needs editing |
| the shape | how the GPU servers in `hosts` add up to instances (`NODES_PER_INSTANCE`, `TP`, `PP`) |
| the engine | engine, image, flags — comes with the example |
| the accelerators | `DOCKER_FLAGS` (devices, environment, a vendor runtime) |
| limits and access | rate limits and authentication — tune after measuring |
| ports, images and SSH | ports, images, the container CLI, SSH — rarely touched |

The URL path is named after the model: `MODEL_NAME` without any `org/` prefix,
lower-cased (`Qwen/Qwen3-32B` serves at `/qwen3-32b/v1`). Set
`ROUTE` in `.env` to choose a different path.

### How many instances

| `NODES_PER_INSTANCE` | Four 8-card GPU servers give | Use it when |
|---|---|---|
| `1` (default) | four instances of 8 cards, balanced by CART | the weights fit in one GPU server: more throughput, no collectives across servers, a failure costs one instance |
| `4` | one instance of 32 cards | the weights do not fit in one GPU server |

GPU servers are taken in file order; the first GPU server of each instance is rank 0, the
only one that serves the API. `up.sh` refuses a shape where `TP × PP` does not equal
`DEVICES_PER_NODE × NODES_PER_INSTANCE`, or where the server count does not divide.
An instance spanning GPU servers also needs its network interface named in
`DOCKER_FLAGS` (see Prerequisites), and is restarted as a whole — the containers run
with `--restart no`, because a lone rank coming back waits at a rendezvous forever.

### Different hardware

There is no vendor-specific code; the hardware is two variables:

| Variable | What it is |
|---|---|
| `ENGINE_IMAGE` | the engine build for this hardware |
| `DOCKER_FLAGS` | every extra container argument, verbatim: devices, `-e`, mounts, a vendor runtime. `{HOST}` is replaced with the GPU server's own address |

`--network host --ipc=host`, the memlock/stack ulimits, the weights mount and a cache
directory are always added. Keep `DOCKER_FLAGS` on one line. Also note:

- **Accelerators must be requested in `DOCKER_FLAGS`.** On NVIDIA it is `--gpus`. On
  Ascend it is `--runtime ascend -e ASCEND_VISIBLE_DEVICES=0-7`, which needs `ascend`
  listed under Runtimes in `docker info`. The Ascend Docker Runtime installer registers
  it when docker is already installed; if it is missing, add it to
  `/etc/docker/daemon.json` and restart dockerd:
  `"runtimes": {"ascend": {"path": "/usr/local/Ascend/Ascend-Docker-Runtime/ascend-docker-runtime"}}`.
  docker takes the registered name, not the path.
- **No CPU or memory limit** unless you add `--cpus` / `--memory` to `DOCKER_FLAGS`.

Mixing hardware in one deployment is not supported (the route's latency limits are
judged across all instances); run a second deployment with its own model name.

### Rate limits

| Setting | Default | What it does |
|---|---|---|
| `MAX_CONCURRENCY` | `100` | Requests in flight per instance at the gateway; the route's limit is this × healthy instances |
| `TTFT_LIMIT_MS` | `30000` | When the average time to first token reaches this, new requests get `429` |
| `TPS_LIMIT_TPS` | `20` | Target decode rate per request, in tokens/s; below it, adaptive concurrency lowers the limit |
| `ADAPTIVE_CC` | `true` | Adaptive concurrency; `false` keeps the full `MAX_CONCURRENCY` and rejects with `429` when the decode rate is below target |
| `ADAPTIVE_CC_MIN_FRAC` | `0.4` | Lowest adaptive limit, as a fraction of `MAX_CONCURRENCY` |
| `CART_MAX_LOAD` | `50` | Requests in flight per instance at CART |
| `MAX_BODY_SIZE` | `209715200` | Largest request body in bytes (200 MiB), for the gateway and CART alike |

Over a limit is an immediate `429` with `Retry-After: 1`; nothing is queued.

### Applying changes

Re-run `./up.sh`. It keeps every engine whose configuration is unchanged and still
running, reloads openresty gracefully, and signals CART to re-read its worker list.

| Change | In-flight requests |
|---|---|
| Limits, route name, adding or removing GPU servers | kept — only new GPU servers start, removed ones need `docker rm -f engine-<route>` on that GPU server |
| Engine flags, `TP`/`PP`, image | cut on the GPU servers whose engine changed — those are recreated |
| Any CART field other than its workers | restart CART: `docker compose restart cart` |
| Force every engine to restart | `FORCE_ENGINES=1 ./up.sh` |

### Authentication

The gateway reads its keys from `keys/keys` (`API_KEYS_DIR`, default `./keys`). While
that file does not exist, every request is let through and `_health_status` reports
`api_keys_configured=false`. To turn authentication on:

```bash
echo 'sk-one:team-a,sk-two:team-b' > keys/keys
./up.sh
```

Requests then need `Authorization: Bearer <key>`. Re-running `./up.sh` reloads the keys
without a restart, so a new key can be added beside the old one before the old one
is removed. The `/<route>/_*` status endpoints are never authenticated.

## Troubleshooting

Start with `./status.sh`. The gateway's own status endpoints, on the control machine:

```bash
curl -s http://127.0.0.1:<GATEWAY_PORT>/<route>/_health_status   # each peer: active or banned
curl -s http://127.0.0.1:<GATEWAY_PORT>/<route>/_tps_status      # decode rate, adaptive limit
curl -s http://127.0.0.1:<GATEWAY_PORT>/<route>/_429_status      # rejections by reason
```

| Symptom | Check |
|---|---|
| `502` on the route | the first path segment is not the route `up.sh` printed, or no engine is reachable yet (`./status.sh`) |
| `503` | every peer failed its health check: `_health_status`, then `docker logs engine-<route>` on the GPU server |
| `429` at low load | adaptive concurrency at its floor: `_tps_status`, and whether `TPS_LIMIT_TPS` is reachable on this hardware |
| An instance never becomes ready | `docker logs engine-<route>` on rank 0, and on every rank of a multi-server instance |
| Which instance served a request | set `EXPOSE_ROUTED_PEER=true` and re-run `./up.sh`: responses then carry `X-Routed-Peer` |

## Not provided

Nothing restarts a failed instance, and there is no autoscaling, no backend discovery
(`hosts` is the truth), no rolling update, and one model per deployment — a second
model is a second copy of `docker/` with its own model name, ports and GPU servers.
