# Scheduler

Cluster-scoped scheduling policy for the inference stack. Nothing here owns a
workload — these are the objects workloads reference by name.

```
.
├── priority-classes.yaml   # three-tier PriorityClass set: prod / canary / batch
├── volcano/                # Volcano scheduler — gang scheduling for LWS groups
└── README.md               # CURRENT FILE
```

## Apply

```bash
kubectl apply -f scheduler/priority-classes.yaml
```

Apply this **before** any workload that names one of these classes. A pod
referencing a PriorityClass that does not exist is rejected at admission — it
never reaches the scheduler, so it does not even show up as Pending.

## The tiers

| Class | value | preemptionPolicy | For |
| --- | --- | --- | --- |
| `inference-prod` | 100000 | `Never` | Online serving — the kimi-k2.5 LWS groups, modelforge |
| `inference-canary` | 10000 | `Never` | Canary / shadow-traffic instances; no current user |
| `inference-canary-preempting` | 10000 | `PreemptLowerPriority` | Same tier, but clears batch work to get scheduled — single-pod Deployments only |
| *(unset)* | 0 | — | Anything not labelled; sits between canary and batch |
| `batch-preemptible` | -10 | default | Offline and batch work, first out when capacity is short |

`value` is the tier; the `-preempting` suffix is the behaviour. Two classes at the
same value differing only in `preemptionPolicy` is deliberate: `preemptionPolicy`
is immutable once a class exists and a pod cannot override it in its own spec, so
the only way to switch a workload between "waits" and "clears space" is to point it
at a different class — one line in the workload, no class surgery.

Reach for the preempting variant only when all three hold: there are genuinely
lower-priority pods to evict on those nodes, the workload is a single pod that runs
as soon as it lands on one node, and waiting for capacity to free up on its own is
not acceptable. Miss the first and preemption is a no-op; miss the second and a
half-won preemption kills someone else's pods while yours still cannot start.

Every live service belongs on `inference-prod`, modelforge included: being the
*fallback* target in the routing topology says where traffic goes, not how much the
service matters. The second tier is named `canary` rather than `fallback` for
exactly that reason — it is for workloads that can genuinely be given up first
(canaries, shadow traffic), not for the fallback deployment.

Infrastructure keeps the built-in classes it already uses — `system-node-critical`
and `system-cluster-critical` (2e9 and above, for cilium, ceph-csi, gpu-operator).
The inference tiers top out at 1e5 on purpose: serving matters, but not more than
the CNI and the storage layer it runs on.

## Wiring it up

Workloads set the class themselves; this directory does not patch them.

- `kimi-k2.5/kimi-lws.yaml` — `spec.priorityClassName` in both `leaderTemplate`
  and `workerTemplate`. Same class for both: preempting either member costs the
  whole group, so ranking them differently buys nothing.
- The `sglang` Helm chart (`helm-charts/charts/sglang`) — top-level
  `priorityClassName` in values, which reaches the Deployment pod and the LWS
  leader and worker. Side-car components (cart, metrics-mock) do not read it.
  A single-node Deployment (modelforge, 2 GPUs) is the shape the `-preempting`
  variant is meant for; anything under `lws.enabled` is not. Note that modelforge
  is production and so runs on `inference-prod`, which has no preempting variant —
  add `inference-prod-preempting` by the same convention if it ever needs one.

## What priority does and does not buy

It buys **queue order** — a higher-priority pod is considered before lower-priority
ones and gets first claim on capacity as it frees up — and a **say in who loses**
when capacity is short, both for preemption victims and for kubelet's node-pressure
eviction ordering.

It does **not** defragment anything. Preemption frees space on one node by killing
lower-priority pods there; it never repacks running pods, and with nothing lower
priority in the cluster it does nothing at all.

Both inference tiers therefore carry `preemptionPolicy: Never`. Preemption is
per-pod and blind to an LWS group: a kimi-k25 group is a leader and a worker
holding 8 GPUs each across two nodes, and a preemptor that wins the leader's node
but loses the worker's has killed someone else's pods *and* is sitting on 8 idle
GPUs it cannot use. `Never` disables only the "preempt others" half — such a pod
can still be preempted by a higher-value one, and its queue ordering is unaffected.
Gang-aware preemption needs a gang scheduler (volcano, koordinator), not a bigger
number here — see `volcano/`, which installs one. Its `preempt` action is not wired
up; installing it does not change the tiers above.

Note which way that dependency runs, though: **this file is part of what would have
to change**. Volcano reads `pod.spec.preemptionPolicy`, so the `Never` on both
inference tiers blocks its gang-aware preemption exactly as it blocks
kube-scheduler's — measured, with the scheduler logging `not eligible to preempt
other tasks due to preemptionPolicy is Never`. And preemption needs the victim in a
*lower* tier, which the rule above ("every live service belongs on
`inference-prod`, modelforge included") rules out by design. Both are deliberate
choices; reversing either is a decision about which service gets sacrificed.
`volcano/README.md` has the full list of prerequisites.

`value` and `preemptionPolicy` are immutable once created: re-tiering means delete
and recreate. Deleting a class does not disturb running pods — their priority was
stamped into `pod.spec` at admission — but new pods naming it are rejected until it
is back, so do it between rollouts.
