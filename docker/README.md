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

`up.sh` returns once every instance serves (up to 90 minutes) and has answered one
warm-up request -- the first request on a fresh engine compiles kernels and can take a
minute or more, so `up.sh` pays that instead of your first user. It then prints the
service, for example:

```
=== model service
  endpoint   http://10.0.0.21:8080/glm-5.3-flash/v1        (OpenAI-compatible)
  model      glm-5.3-flash
  instances  1 of 1 ready
  try        curl http://10.0.0.21:8080/glm-5.3-flash/v1/chat/completions -H 'Content-Type: application/json' \
               -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hello"}],"max_tokens":256}'
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
running, reloads openresty gracefully, and has CART pick up its new configuration.

| Change | In-flight requests |
|---|---|
| Limits, adding GPU servers | kept — only the new GPU servers start |
| Removing GPU servers from `hosts` | kept on the others; the removed servers' engines are stopped once the route no longer sends them traffic |
| Model name or route name | cut — the previous engines are removed first, since the new ones need the same ports |
| Engine flags, `TP`/`PP`, image | cut on the GPU servers whose engine changed — those are recreated |
| `MAX_BODY_SIZE` | cut for requests passing through CART — `up.sh` restarts CART, which re-reads only its worker list on a reload |
| Force every engine to restart | `FORCE_ENGINES=1 ./up.sh` |

### Authentication

The gateway reads its keys from `keys/keys` (`API_KEYS_DIR`, default `./keys`). While
that file does not exist, every request is let through. To turn authentication on:

```bash
echo 'sk-one:team-a,sk-two:team-b' > keys/keys
./up.sh
```

Requests then need `Authorization: Bearer <key>`. Re-running `./up.sh` reloads the keys
without a restart, so a new key can be added beside the old one before the old one
is removed. The `/<route>/_*` status endpoints are never authenticated.

## Troubleshooting

Start with `./status.sh`; an engine's own log is `docker logs engine-<route>` on its GPU
server.

**`./up.sh` exits with an error**

| What you see | Likely cause | Fix |
|---|---|---|
| `TP(…) x PP(…) = … but an instance is …` | `TP × PP` ≠ `DEVICES_PER_NODE × NODES_PER_INSTANCE` | Make them match in `.env` |
| `… machine(s) do not divide into instances of …` | Server count in `hosts` not a multiple of `NODES_PER_INSTANCE` | Fix `hosts` or `NODES_PER_INSTANCE` |
| `Permission denied (publickey)` / `… did not start` | No passwordless SSH from the control machine to that server | Add the control machine's key to the server's `authorized_keys` |
| `weights not found: …` | `MODEL_PATH` missing on that server | Copy the weights there, same path on every server |
| `unknown or invalid runtime name` | Ascend runtime given as a path, or not registered with docker | `--runtime ascend`, registered in `/etc/docker/daemon.json` (see Different hardware) |
| `port(s) in use on this machine` | `GATEWAY_PORT` or `CART_PORT` taken by something else | Free the port or change it in `.env` |

**An instance never becomes ready** (`./status.sh` shows `loading` or `stopped`)

| What you see in the engine log | Likely cause | Fix |
|---|---|---|
| No GPU / NPU found, fails on first allocation | Accelerators not requested in `DOCKER_FLAGS` | `--gpus …` (NVIDIA), or `--runtime ascend` with both `ASCEND_VISIBLE_DEVICES` and `ASCEND_RT_VISIBLE_DEVICES` (Ascend) |
| `To serve at least one request with the model's max seq len …` | The context length does not fit in GPU memory | Lower `--max-model-len` or raise `--gpu-memory-utilization` in `ENGINE_EXTRA_ARGS` |
| An argument error naming a JSON flag | A JSON value in `ENGINE_EXTRA_ARGS` without its own single quotes | Write it as `--flag='{"a":1}'` |
| Loads, then stops progressing (multi-server instance) | The servers connect over an interface they cannot reach each other on, or `DIST_PORT` is blocked | Name the interface in `DOCKER_FLAGS` (see Prerequisites); open `DIST_PORT` |

**Requests fail**

| Response | Likely cause | Fix |
|---|---|---|
| `502` | The path is not the route `up.sh` printed, or no engine is serving yet | Use the printed endpoint; check `./status.sh` |
| `503` | Every instance failed its health check | `./status.sh`, then the engine logs |
| `401` | `keys/keys` exists and the request has no valid key | Send `Authorization: Bearer <key>` |
| `413` | Request body larger than `MAX_BODY_SIZE` | Raise `MAX_BODY_SIZE` and re-run `./up.sh` |
| `429` at low load | `TPS_LIMIT_TPS` higher than this hardware decodes, so adaptive concurrency sits at its floor; or `MAX_CONCURRENCY` too low | Lower `TPS_LIMIT_TPS`, or raise `MAX_CONCURRENCY` |
| `404` / model does not exist | The request's `model` is not `MODEL_NAME` | Send the model name `up.sh` printed |

## Limitations

Not included:

- **Automatic recovery.** A failed engine is not restarted; run `./up.sh` again.
- **Autoscaling.** The number of instances is fixed by `hosts`.
- **Service discovery.** Backends come only from `hosts`; a change there takes effect
  on the next `./up.sh`.
- **Rolling updates.** Changing an engine's configuration recreates it, and requests in
  flight on it are dropped.
- **High availability for the routing layer.** openresty and CART run on a single
  control machine.
- **Monitoring and alerting.** No metrics collection or dashboards are deployed.

Constraints:

- **One model per deployment.** Serve another model from a separate copy of `docker/`,
  with its own ports.
- **One engine container per GPU server.**
- **One hardware type per deployment**, since the route's latency limits are judged
  across all instances.
