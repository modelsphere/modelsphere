# Running ModelSphere without Kubernetes

One model, served on a set of machines, with containers and two files. Use this when
there is no cluster -- a handful of machines, a proof of concept, an air-gapped rack
-- and [the Kubernetes path](install.md) for the parts that need one (see
[what you give up](#what-this-path-does-not-give-you)).

Everything lives in [`docker/`](../docker).

## What runs where

```
                      control machine (no accelerator needed)
                      ┌───────────────────────────────────────┐
  client ── :8080 ──► │ openresty   one port, limits, records │
                      │     │                                 │
                      │     ▼                                 │
                      │ cart        cache-aware routing       │
                      └─────┬─────────────────────────────────┘
                            │  rank 0 of each instance, by address
          ┌─────────────────┼──────────────────┐
          ▼                 ▼                  ▼
       machine           machine            machine      ← accelerators; one
       (one container, host network, one instance or one shard of one)  container each
```

The routing layer is `docker compose`. The engines are not: each machine runs one
container with host networking and devices, and its command differs by rank, so
`render.sh` writes one launch script per machine and `up.sh` runs them one at a time
over SSH. Both halves come from the same two files, so the route's peer list and the
engines' rendezvous addresses cannot drift apart.

## Before you start

Nothing here installs any of this, and most of it fails looking like a hung engine
rather than a missing dependency. [`docker/README.md`](../docker/README.md#0-the-machines-have-to-be-ready-first)
has the same list as a checklist with the command for each line.

**Control machine** (no accelerator; may be one of the engine machines):

- **docker with the compose plugin.**
- **Passwordless SSH to every engine machine** as `SSH_USER`, for every line in
  `hosts`: `up.sh` visits them one at a time and cannot answer a password prompt.
- **A free `GATEWAY_PORT`, and a `NET_SUBNET` that is not already routed.** A compose
  network overlapping a real range breaks whatever was using it.
- It must be able to pull the routing images. They are published for amd64 and arm64,
  so this may be an aarch64 box.

**Every engine machine:**

- **A container CLI**: Docker, or **nerdctl** where there is no Docker daemon
  (`CTR_CLI`). On a machine that is also a Kubernetes node nerdctl is the better
  choice -- it drives the containerd already there instead of adding a second image
  store. (Keep `CTR_NAMESPACE` off `k8s.io`, which is kubelet's.)
- **The accelerator's driver, on the host and healthy** -- `nvidia-smi` or
  `npu-smi info` must work. The container does not carry a driver.
- **The container runtime hook for that accelerator**: `nvidia-container-toolkit` so
  `--gpus` works, or a vendor OCI runtime, or the device mounts in its place. Without
  it the container starts with no accelerator in it. See
  [different hardware](#different-hardware); the stack itself has no opinion about
  which.
- **The weights on local disk, one copy per machine.** There is no shared-storage
  path here.
- A free `ENGINE_PORT`, reachable from the control machine.

**Only for a multi-machine instance** (`NODES_PER_INSTANCE` > 1), and all of these
fail silently -- the model loads and then hangs at its first collective:

- **RDMA/InfiniBand ready** if you want it: `ibstat` ports `Active` and
  `/dev/infiniband` present, with the device named in `DOCKER_FLAGS`.
- **The collective interface named** (`NCCL_SOCKET_IFNAME` / `HCCL_SOCKET_IFNAME`).
- **`DIST_PORT` free on every machine of the instance and reachable between them.**

## Configure: two files

```bash
cd docker
cp examples/ascend-glm53-flash.env .env  # ls examples/ -- start from the closest one
cp hosts.example hosts                  # the machines, one address per line
# edit both, then
./up.sh
```

`.env` holds everything; `hosts` is just the machine list. `examples/` holds complete
starting points, one per hardware and model that has actually been run -- each is a
whole file, so copying one gives you a consistent configuration rather than a
template with blocks to comment in and out. Your `.env` and `hosts` are gitignored,
because they hold your real addresses. (`.env` keeps that name because docker compose
loads it by itself.)

`up.sh` renders first, every time, so there is no separate step to forget. Rendering
writes `generated/`: the route, CART's config, and one launch script per machine --
the exact configuration and the exact container command that will run. **To see what
would be applied without applying it, run `./render.sh` and read `generated/`.**

```bash
curl http://127.0.0.1:8080/qwen/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-72B-Instruct","messages":[{"role":"user","content":"hello"}]}'
```

The first path segment is `ROUTE`, not the model name; the two may differ. A model
loads for minutes while its container starts in seconds, so `up.sh` waits for
`/v1/models` rather than for the container. `./down.sh` stops everything.

## How many instances?

Four machines of eight cards is 32 cards either way. `NODES_PER_INSTANCE` in `.env`
is how you say what you want:

| | You get | Use it when |
|---|---|---|
| `NODES_PER_INSTANCE=1` (default) | **four instances of 8 cards**, balanced by the router | the weights fit in one machine -- four times the throughput, no cross-machine collectives, and one failure costs a quarter of the capacity rather than all of it |
| `NODES_PER_INSTANCE=4` | **one instance of 32 cards**: one set of weights, one KV cache, collectives over the network | the weights do not fit in one machine |

Machines are taken in file order, so with `NODES_PER_INSTANCE=2` the first two lines
of `hosts` are one instance and the next two are another. `TP x PP` must equal
`DEVICES_PER_NODE x NODES_PER_INSTANCE`, and the machine count must divide by
`NODES_PER_INSTANCE`; `render.sh` checks both, because otherwise a leftover machine
quietly serves nothing and a wrong `TP x PP` makes the engine exit with a complaint
that never mentions these files.

Only the first machine of an instance serves the API. That one is rank 0 and the only
one the routers are told about -- the others hold shards and answer nothing.

Two things about multi-machine instances that differ from Kubernetes:

- **Name the collective interface** in `DOCKER_FLAGS` (`-e NCCL_SOCKET_IFNAME=...`,
  `-e HCCL_SOCKET_IFNAME=...`). Left unset on a machine with several interfaces, the engine
  picks one that cannot reach its peer: the model loads and then hangs at the first
  collective, with nothing in the log that says so.
- **An instance is atomic, and nothing here restarts it.** The generated scripts use
  `--restart no` deliberately: a lone rank coming back waits at a rendezvous nobody
  else is attending, so the container looks alive and serves nothing. Recovery is
  `./down.sh` then `./up.sh`. On Kubernetes, LeaderWorkerSet and hang-watcher do this.

## Different hardware

The stack has no vendor-specific code in it. Whatever hands a container its
accelerators is container flags, so that is what `.env` asks for:

| Variable | What it is |
|---|---|
| `ENGINE_IMAGE` | the engine build for this hardware |
| `DOCKER_FLAGS` | **all** extra container arguments, verbatim: devices, `-e`, mounts, a vendor runtime. One variable, so there is one place to look (nerdctl takes the same flags) |
| `PRE_START` | anything that must run inside the container before the engine |
| `{HOST}` | substituted with the machine's own address, in either of the two above |

`--network host --ipc=host --ulimit memlock=-1 --ulimit stack=67108864`, the weights
mount and a cache directory are there for every engine already; `DOCKER_FLAGS` is
what your hardware adds on top. Keep it on one line -- the file is read by the shell
and by docker compose, and only one of them is relaxed about continuations.

`examples/` holds the worked ones -- `ascend-glm53-flash.env` is a GLM-5.3-Flash
W8A8 deployment on Ascend 910B4, with the flags, the image and the concurrency cap it
was benchmarked with. The values below are the shape of each:

```bash
# NVIDIA
ENGINE_IMAGE=lmsysorg/sglang:v0.5.15-cu129
DOCKER_FLAGS="--gpus '\"device=0,1,2,3\"' --device /dev/infiniband -e NCCL_SOCKET_IFNAME=bond0 -e GLOO_SOCKET_IFNAME=bond0 -e NCCL_IB_HCA=mlx5_0"

# Ascend NPUs (aarch64; ENGINE=vllm, since SGLang has no NPU build)
ENGINE_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0
DOCKER_FLAGS="--runtime /usr/local/Ascend/Ascend-Docker-Runtime/ascend-docker-runtime -e ASCEND_VISIBLE_DEVICES=0-7 -e HCCL_IF_IP={HOST} -e HCCL_SOCKET_IFNAME=bond1 -e TP_SOCKET_IFNAME=bond1"
PRE_START="printf '%s\n' /usr/local/Ascend/driver/lib64 ... > /etc/ld.so.conf.d/ascend_driver.conf; ldconfig"
```

Two traps worth knowing before the first run, both measured:

- **Under Kubernetes a device plugin injects the devices and the driver, so manifests
  there need neither mounts nor a runtime. With plain containers nothing injects
  anything** and you have to ask explicitly. A pod spec copied from a cluster starts
  a container with no accelerator in it.
- **A `default_runtime_name` in containerd's CRI config does not apply here.** That
  setting is kubelet's; both docker and nerdctl default to runc and need the runtime
  named. The failure is quiet -- the container runs and the devices are not there.
- **Ascend's driver is mounted at runtime**, so it is not on the loader path the image
  was built with; without `PRE_START` the engine cannot load its NPU backend.

Mixing hardware in one deployment is not supported, and the reason is not just
plumbing: the TTFT and decode-rate judgements are made for the route as a whole, so a
slower instance raises the average and the limiter then sheds traffic the faster
instances could have served. Run a second deployment with its own `ROUTE` instead.

## Rate limiting, and applying changes

The knobs are the ones in [openresty.md](openresty.md#route-limits), set in `.env`
rather than a chart: `MAX_CONCURRENCY` (per instance), `TTFT_LIMIT_MS`,
`TPS_LIMIT_TPS`, `ADAPTIVE_CC`, `ADAPTIVE_CC_MIN_FRAC`. Nothing is queued -- over a
limit is an immediate `429` with `Retry-After: 1`, and every route has limits even if
you change nothing.

| Change | Apply with | In-flight requests |
|---|---|---|
| Limits, machine list, route name | `SKIP_ENGINES=1 ./up.sh` -- renders, then reloads openresty | kept |
| API keys | edit the key file, then `docker compose exec openresty openresty -s reload` | kept |
| CART's **worker list** | `./render.sh` then `docker compose kill -s HUP cart` | kept |
| Any other CART field (cache, proxy, server) | restart the container: its SIGHUP handler takes a changed worker list and **rejects everything else** | cut |
| Engine flags, `TP`/`PP`, image | `./down.sh` then `./up.sh` | cut |

The engine's command line is built by `render.sh` from `ENGINE`, the port, `TP`/`PP`
and the multi-machine arguments; `ENGINE_EXTRA_ARGS` is appended to it verbatim, and
**`ENGINE_CMD` replaces it entirely** for an image that starts in its own way (it gets
`{HOST}`, `{PORT}`, `{RANK}`, `{NNODES}`, `{LEADER}`, `{DIST_PORT}`, `{MODEL_NAME}`,
`{TP}`, `{PP}` substituted per machine, and must `exec` in the foreground). Either
way, what will run is in `generated/engine-<address>.sh` before it runs.

Four flags are always added and are not optional: `--enable-metrics`,
`--enable-cache-report` and `--stream-response-default-include-usage` on SGLang,
`--enable-prompt-tokens-details` on vLLM. The decode-rate limit is read from the
`usage` in each response, so without them adaptive concurrency has no input. With
`ENGINE_CMD` you are responsible for their equivalents.

## Authentication

**Off by default**: with no key file openresty lets every request through and reports
`api_keys_configured=false` in `/_health_status`. That is a deliberate fail-open --
a broken key mount that 401s a whole gateway is worse than a window without auth --
and it is why that field is worth alerting on.

To turn it on, put `key:owner,key:owner` in a file named `keys` and point `.env` at
its directory:

```bash
mkdir -p keys && echo 'sk-one:team-a,sk-two:team-b' > keys/keys
# .env:  API_KEYS_DIR=./keys
docker compose up -d && docker compose exec openresty openresty -s reload
```

Several keys at once is what makes rotation possible: add the new one beside the old,
move callers over, drop the old one, reload. No restart, so nothing streaming is cut.

Note that the `/<route>/_*` status endpoints have no authentication in any case, and
they list the engines' addresses -- so do not expose port 8080 as it is.

## Request and response records (optional)

Off by default: with no listener address openresty builds and sends nothing, and
there is deliberately no fallback. To collect them, set
`BODYLOG_LISTENER_HOST=bodylog` and bring the stack up with `--profile bodylog`.
Records land in `docker/data/bodylog/`, and `/summary` on port 9998 (loopback only --
they contain whole request bodies) says whether frames are arriving. If the listener
is unreachable, requests are unaffected: each worker buffers and then drops, counting
`drop_count`.

## Check that it works

```bash
curl -s http://127.0.0.1:8080/<route>/_health_status   # each peer: active or banned
curl -s http://127.0.0.1:8080/<route>/_tps_status      # decode rate, adaptive limit
curl -s http://127.0.0.1:8080/<route>/_ttft_status     # TTFT average, enforcing or not
curl -s http://127.0.0.1:8080/<route>/_429_status      # rejections by reason
```

| Symptom | Do |
|---|---|
| `502` on the route | the path's first segment is not `ROUTE`, or nothing was rendered -- check `generated/routes/` |
| `503` with `Retry-After: 5` | every peer failed its health check; `_health_status`, then the engine on the machine |
| `429` at low load | adaptive concurrency is at its floor; check `_tps_status` and whether `TPS_LIMIT_TPS` is reachable on this hardware |
| An instance never becomes ready | `<CTR_CLI> logs engine-<route>` on rank 0; for a multi-machine instance also on the other ranks, where a wrong collective interface shows up |
| The engine rejects a JSON flag | a JSON value in `ENGINE_EXTRA_ARGS` needs single quotes of its own (`--compilation-config '{"x":1}'`). These flags reach a command line the shell parses, and bare JSON loses its quotes and splits on the comma |
| A limit change had no effect | openresty was not reloaded -- `SKIP_ENGINES=1 ./up.sh`, and check the value in `generated/routes/route.conf` |
| No way to tell which instance served a request | set `EXPOSE_ROUTED_PEER=true` and re-apply: responses then carry `X-Routed-Peer`. It is off by default because it names the backend's address |
| CART looks healthy while the model is down | it should not: the generated route probes CART on `/health`, not `/v1/models`, which answers 200 with every worker down |

## What this path does not give you

The reason the Kubernetes path exists. All of these are there and none of them here:

- **Nothing restarts a failed instance.** A multi-machine instance must be restarted
  as a whole, by you.
- **No autoscaling**, on SLO targets or anything else.
- **No peer discovery.** `hosts` is the truth; a machine that moves means editing it
  and running `./up.sh` again.
- **No rolling update.** Changing the engine means stopping it.
- **One model per deployment.** A second model is a second copy of `docker/` with its
  own `ROUTE`, port and machines.
- **One control machine**, and it is the single point of failure for the route.
