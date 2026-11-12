# ModelSphere without Kubernetes

One model, served on a set of machines, with containers.

```bash
# 1. start from the example closest to your hardware
cp examples/ascend-glm53-flash.env .env   # ls examples/ for the others
cp hosts.example hosts                   # your machines, one address per line

# 2. edit .env (the model, the weights path, the limits) and hosts, then
./up.sh            # renders, starts the engine on every machine, starts the router
```

`.env` keeps that name because docker compose loads it by itself; the examples are
visible files so you can see what there is to copy.

`./render.sh` alone renders into `generated/` and applies nothing -- that is how you
read the exact route config and the exact per-machine container command first.
`./down.sh` stops everything.

The guide is [docs/docker-compose.md](../docs/docker-compose.md): how many instances
the machines add up to, NVIDIA and Ascend, rate limiting, authentication, and what
this path does not do that Kubernetes does.
