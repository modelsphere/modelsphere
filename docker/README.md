# Serving a model with Docker

This directory deploys one model on a set of GPU servers using only a container runtime
and SSH. A control machine runs the routing layer with `docker compose`, and each GPU
server runs one engine container. Use it when you have no cluster: a handful of
servers, a proof of concept, or an air-gapped rack.

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

- `.env` describes the model, the engine, the hardware and the limits.
- `hosts` lists the GPU servers, one per line.

## Prerequisites

The deployment scripts do not install or configure any of the following, so verify
each item before the first deployment. A missing prerequisite usually shows up as an
engine that starts but never becomes ready, not as an explicit error.

In the checks below, `<NAME>` stands for the value of that setting in `.env`. Because
`.env` lives on the control machine, substitute the value by hand when you run a check
on a GPU server.

### Control machine

The control machine is where you run `./up.sh`. It needs no accelerator, and it can
be one of the GPU servers.

| Requirement | How to check |
|---|---|
| Docker with the compose plugin | `docker compose version` |
| **Passwordless SSH to every GPU server** as `SSH_USER` (default `root`) | `ssh -o BatchMode=yes root@<gpu-server> true` must succeed without a prompt for every line in `hosts`, because `up.sh` logs in to the GPU servers one at a time and cannot answer a password prompt. The control machine itself needs no SSH: a `hosts` line of `127.0.0.1` or one of its own addresses runs locally, so a single-server deployment needs no SSH at all |
| Network access to each GPU server's `ENGINE_PORT` | Once an engine is running, `curl -m 5 http://<gpu-server>:<ENGINE_PORT>/v1/models` must answer |
| **`GATEWAY_PORT` and `CART_PORT` are free.** The routing containers use host networking and bind these ports directly; `up.sh` checks both before it starts and names any process that holds one | `ss -ltn \| grep -E ':(<GATEWAY_PORT>\|<CART_PORT>) '` |
| The routing images can be pulled | `docker pull <OPENRESTY_IMAGE>` |

### GPU servers

| Requirement | How to check |
|---|---|
| A container CLI: Docker, or nerdctl where no Docker daemon runs (`CTR_CLI`) | `docker version` / `nerdctl version` |
| **The accelerator driver is installed and healthy on the host** | NVIDIA: `nvidia-smi`. Ascend: `npu-smi info`. The container image does not include a driver |
| **The container runtime integration for the accelerator is installed** | NVIDIA: `nvidia-container-toolkit`, which makes `--gpus` work. Ascend: the vendor OCI runtime, or the device mounts that the example lists as an alternative. Without it, the container starts with no accelerator inside and the engine fails on its first allocation |
| The engine image can be pulled, or is already present | `docker image inspect <ENGINE_IMAGE>` |
| **The weights are on local disk, one copy per GPU server** | `ls <MODEL_PATH>`; this deployment does not use shared storage |
| `ENGINE_PORT` is free | `ss -ltn \| grep :<ENGINE_PORT>` |

### Additionally, for an instance that spans GPU servers

These requirements apply only when `NODES_PER_INSTANCE` is greater than 1, that is,
when one model instance runs across several GPU servers. If any of them is not met,
the engine usually loads the model and then stops responding when the servers first
communicate, and no error message points to the cause.

| Requirement | How to check |
|---|---|
| **RDMA/InfiniBand is ready**, if you intend to use it: the ports are up and the devices are present | `ibstat` shows every port as `Active`, `ls /dev/infiniband` lists the devices, and `DOCKER_FLAGS` names the device |
| **The network interface that the servers connect over is named explicitly** | Set `-e NCCL_SOCKET_IFNAME=<nic>` (NVIDIA) or `-e HCCL_SOCKET_IFNAME=<nic>` (Ascend) in `DOCKER_FLAGS`. The servers of an instance first find and connect to each other over this host interface. If it is not set and a server has several network interfaces, the engine chooses one automatically and may choose one that the other servers cannot reach, such as a container bridge or a network with no route between the servers; the instance then never finishes connecting. On Ascend, this interface is used only to set up the connection; the collective traffic itself runs over the NPUs' own RoCE ports, which are configured in `/etc/hccn.conf` |
| **`DIST_PORT` is free on every GPU server of the instance and reachable between them** | `ss -ltn \| grep :<DIST_PORT>` |

## Quick start

```bash
cd docker
cp examples/glm-5.3-flash-910b4.env .env   # ls examples/ for the others
cp hosts.example hosts                    # this GPU server; edit it for several
# set MODEL_PATH (and MODEL_NAME) at the top of .env, then:
./up.sh
```

`examples/` holds complete, tested configurations, one for each combination of
hardware and model. Copy the closest one instead of filling in a blank template.

`up.sh` first generates the routing configuration and the launch commands from `.env`
and `hosts`. It then starts the engine on every GPU server and waits until each one
serves `/v1/models`: a container starts in seconds, but the weights take minutes to
load. Next, it sends every instance one warm-up request, because the first request on
a fresh engine compiles kernels and can take a minute or more; this way, `up.sh` pays
that cost instead of your first user. Finally, it starts the routing layer and prints
the service, for example:

```
=== model service
  endpoint   http://10.0.0.21:8080/glm-5.3-flash/v1        (OpenAI-compatible)
  model      glm-5.3-flash
  instances  1 of 1 ready
  auth       OFF -- anyone who can reach 10.0.0.21:8080 can call it; to turn it on, put keys
             in ./keys/keys and run ./up.sh (README: Authentication)
  limits     off (RATE_LIMIT=false)
  try        curl http://10.0.0.21:8080/glm-5.3-flash/v1/chat/completions -H 'Content-Type: application/json' \
               -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hello"}],"max_tokens":256}'
```

`up.sh` waits up to 90 minutes for the instances to become ready.

| Command | What it does |
|---|---|
| `./up.sh` | Starts everything and returns once every instance serves |
| `./up.sh --no-wait` | Starts everything and returns immediately |
| `./status.sh` | Shows the state of each instance (serving, loading or stopped), the routing layer and the endpoint, and exits 0 once everything serves |
| `./down.sh` | Stops everything |

## Configuration

| File | What it is |
|---|---|
| `.env` | All settings. It is gitignored |
| `hosts` | The GPU servers, one per line. Add a second column only when SSH and the data network use different addresses. It is gitignored |
| `keys/` | The API keys (see Authentication). It is gitignored |
| `generated/` | Files that are generated from `.env` and `hosts` on every run. Do not edit them, and do not delete the directory while the deployment is running, because openresty and CART read their configuration from it. To generate these files without starting anything, and to see exactly what would run, use `./render.sh` |

| Section of `.env` | What it holds |
|---|---|
| the model | What you serve and where its weights are. You always need to edit it |
| the shape | How the GPU servers in `hosts` form instances (`NODES_PER_INSTANCE`, `TP`, `PP`) |
| the engine | The engine, its image and its flags. The example already provides them |
| the accelerators | `DOCKER_FLAGS`: devices, environment variables and a vendor runtime |
| limits and access | Rate limits and authentication. Tune them after you have measured your load |
| ports, images and SSH | Ports, images, the container CLI and SSH. You rarely need to change them |

The URL path is derived from the model name: it is `MODEL_NAME` lower-cased and
without any `org/` prefix. For example, `Qwen/Qwen3-32B` is served at
`/qwen3-32b/v1`. To use a different path, set `ROUTE` in `.env`.

### How many instances

| `NODES_PER_INSTANCE` | Four 8-card GPU servers give you | Use it when |
|---|---|---|
| `1` (default) | Four instances of 8 cards each, balanced by CART | The weights fit on one GPU server. This gives more throughput, needs no collectives across servers, and a failure costs only one instance |
| `4` | One instance of 32 cards | The weights do not fit on one GPU server |

`up.sh` takes the GPU servers in file order. The first GPU server of each instance is
rank 0, and it is the only one that serves the API. `up.sh` rejects a shape in which
`TP × PP` does not equal `DEVICES_PER_NODE × NODES_PER_INSTANCE`, or in which the
number of servers is not a multiple of `NODES_PER_INSTANCE`. An instance that spans
GPU servers also needs its network interface named in `DOCKER_FLAGS` (see
Prerequisites), and it is restarted as a whole: its containers run with
`--restart no`, because a single rank that restarts alone waits for the others
forever.

### Different hardware

The scripts contain no vendor-specific code. Two variables describe the hardware:

| Variable | What it is |
|---|---|
| `ENGINE_IMAGE` | The engine build for this hardware |
| `DOCKER_FLAGS` | Every extra container argument, passed verbatim: devices, `-e`, mounts and a vendor runtime. `{HOST}` is replaced with the GPU server's own address |

`up.sh` always adds `--network host --ipc=host`, the memlock and stack ulimits, the
weights mount and a cache directory. Keep `DOCKER_FLAGS` on one line. Also note the
following:

- **You must request the accelerators in `DOCKER_FLAGS`.** On NVIDIA, use `--gpus`.
  On Ascend, use `--runtime ascend -e ASCEND_VISIBLE_DEVICES=0-7`, which requires
  `ascend` to be listed under Runtimes in `docker info`. The Ascend Docker Runtime
  installer registers it when Docker is already installed. If it is missing, add the
  following to `/etc/docker/daemon.json` and restart dockerd:
  `"runtimes": {"ascend": {"path": "/usr/local/Ascend/Ascend-Docker-Runtime/ascend-docker-runtime"}}`.
  Docker accepts the registered name, not the path.
- **The engine has no CPU or memory limit** unless you add `--cpus` or `--memory` to
  `DOCKER_FLAGS`.

One deployment cannot mix hardware, because the route judges its latency limits across
all instances. To serve on different hardware, run a second deployment with its own
model name.

### Rate limits

| Setting | Default | What it does |
|---|---|---|
| `RATE_LIMIT` | `false` | Turns the limits below on. While it is `false`, the gateway lets every request through and rejects none with `429` |
| `MAX_CONCURRENCY` | `100` | The maximum number of requests in flight per instance at the gateway. The route's limit is this value multiplied by the number of healthy instances |
| `TTFT_LIMIT_MS` | `30000` | When the average time to first token reaches this value, new requests receive `429` |
| `TPS_LIMIT_TPS` | `20` | The target decode rate per request, in tokens/s. Below this rate, adaptive concurrency lowers the limit |
| `ADAPTIVE_CC` | `true` | Turns adaptive concurrency on. With `false`, the full `MAX_CONCURRENCY` applies, and requests are rejected with `429` when the decode rate is below the target |
| `ADAPTIVE_CC_MIN_FRAC` | `0.4` | The lowest adaptive limit, as a fraction of `MAX_CONCURRENCY` |
| `CART_MAX_LOAD` | `50` | The maximum number of requests in flight per instance at CART |
| `MAX_BODY_SIZE` | `209715200` | The largest request body in bytes (200 MiB), applied by both the gateway and CART |

With `RATE_LIMIT=true`, a request over a limit receives `429` with `Retry-After: 1`
immediately; nothing is queued.

### Applying changes

To apply a change, run `./up.sh` again. It keeps every engine whose configuration is
unchanged and still running, reloads openresty gracefully, and makes CART pick up its
new configuration.

| Change | Effect on in-flight requests |
|---|---|
| Limits, or adding GPU servers | They continue. Only the new GPU servers start |
| Removing GPU servers from `hosts` | They continue on the other servers. The removed servers' engines are stopped once the route no longer sends them traffic |
| The model name or the route name | They are cut. The previous engines are removed first, because the new ones need the same ports |
| Engine flags, `TP`/`PP` or the image | They are cut on the GPU servers whose engine changed, because those engines are recreated |
| `MAX_BODY_SIZE` | They are cut for requests that pass through CART, because `up.sh` restarts CART: a reload only re-reads its worker list |
| Restarting every engine | Run `FORCE_ENGINES=1 ./up.sh` |

### Authentication

The gateway reads its keys from `keys/keys` (`API_KEYS_DIR`, default `./keys`). While
that file does not exist, the gateway lets every request through. To turn
authentication on:

```bash
echo 'sk-one:team-a,sk-two:team-b' > keys/keys
./up.sh
```

After that, every request must send `Authorization: Bearer <key>`. Running `./up.sh`
again reloads the keys without a restart, so you can add a new key next to the old one
before you remove the old one. The `/<route>/_*` status endpoints never require a key.

## Troubleshooting

Start with `./status.sh`. To read an engine's log, run `docker logs engine-<route>` on
its GPU server.

**`./up.sh` exits with an error**

| What you see | Likely cause | Fix |
|---|---|---|
| `TP(…) x PP(…) = … but an instance is …` | `TP × PP` does not equal `DEVICES_PER_NODE × NODES_PER_INSTANCE` | Make them match in `.env` |
| `… machine(s) do not divide into instances of …` | The number of servers in `hosts` is not a multiple of `NODES_PER_INSTANCE` | Fix `hosts` or `NODES_PER_INSTANCE` |
| `Permission denied (publickey)` / `… did not start` | The control machine has no passwordless SSH to that server | Add the control machine's key to the server's `authorized_keys` |
| `weights not found: …` | `MODEL_PATH` does not exist on that server | Copy the weights to the same path on every server |
| `unknown or invalid runtime name` | The Ascend runtime is given as a path, or it is not registered with Docker | Use `--runtime ascend` and register it in `/etc/docker/daemon.json` (see Different hardware) |
| `port(s) in use on this machine` | Another process holds `GATEWAY_PORT` or `CART_PORT` | Free the port, or change it in `.env` |

**An instance never becomes ready** (`./status.sh` shows `loading` or `stopped`)

| What you see in the engine log | Likely cause | Fix |
|---|---|---|
| No GPU or NPU is found, and the engine fails on its first allocation | The accelerators are not requested in `DOCKER_FLAGS` | Use `--gpus …` (NVIDIA), or `--runtime ascend` with both `ASCEND_VISIBLE_DEVICES` and `ASCEND_RT_VISIBLE_DEVICES` (Ascend) |
| `To serve at least one request with the model's max seq len …` | The context length does not fit in GPU memory | Lower `--max-model-len`, or raise `--gpu-memory-utilization`, in `ENGINE_EXTRA_ARGS` |
| An argument error that names a JSON flag | A JSON value in `ENGINE_EXTRA_ARGS` lacks its own single quotes | Write it as `--flag='{"a":1}'` |
| The model loads and then stops progressing (multi-server instance) | The servers connect over an interface on which they cannot reach each other, or `DIST_PORT` is blocked | Name the interface in `DOCKER_FLAGS` (see Prerequisites), and open `DIST_PORT` |

**Requests fail**

| Response | Likely cause | Fix |
|---|---|---|
| `502` | The path is not the route that `up.sh` printed, or no engine is serving yet | Use the printed endpoint, and check `./status.sh` |
| `503` | Every instance failed its health check | Check `./status.sh`, then the engine logs |
| `401` | `keys/keys` exists, and the request has no valid key | Send `Authorization: Bearer <key>` |
| `413` | The request body is larger than `MAX_BODY_SIZE` | Raise `MAX_BODY_SIZE`, and run `./up.sh` again |
| `429` at low load | `RATE_LIMIT=true`, and `TPS_LIMIT_TPS` is higher than this hardware can decode, so adaptive concurrency stays at its floor; or `MAX_CONCURRENCY` is too low | Lower `TPS_LIMIT_TPS`, or raise `MAX_CONCURRENCY` |
| `404`, or "model does not exist" | The request's `model` is not `MODEL_NAME` | Send the model name that `up.sh` printed |

## Limitations

This deployment does not include:

- **Automatic recovery.** A failed engine is not restarted; run `./up.sh` again.
- **Autoscaling.** `hosts` fixes the number of instances.
- **Service discovery.** The backends come only from `hosts`, and a change to it takes
  effect on the next `./up.sh`.
- **Rolling updates.** A change to an engine's configuration recreates the engine,
  and the requests in flight on it are dropped.
- **High availability for the routing layer.** openresty and CART run on a single
  control machine.
- **Monitoring and alerting.** No metrics collection or dashboards are deployed.

It also has these constraints:

- **One model per deployment.** To serve another model, use a separate copy of
  `docker/` with its own ports.
- **One engine container per GPU server.**
- **One hardware type per deployment**, because the route judges its latency limits
  across all instances.
