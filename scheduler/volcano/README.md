# Volcano

Gang scheduling for LWS groups. A `kimi-k2.5` replica is a leader and a worker each
holding a whole 8-GPU machine, and the default scheduler admits them one at a time:
the leader lands on the last free machine, the worker finds none, and the group sits
there forever holding 8 GPUs it cannot serve from. Nothing self-heals — the leader
will not move. Volcano schedules the group as a unit, so either both members land or
neither does and no card is taken.

```
.
├── values.yaml            # HA shape, private-registry images, and the scheduling policy
├── volcano-1.15.1.tgz     # the chart, vendored: the clusters cannot reach github.com
├── pdb.yaml               # one PodDisruptionBudget per component -- the chart has none
└── README.md              # CURRENT FILE
```

## Apply

This is now a helmfile release — `volcano` in `volcano-system`, pulled from
upstream (`volcano-sh/volcano`, repo `https://volcano-sh.github.io/helm-charts`),
with `enabled.volcano` / `enabled.volcanoPdb` in `environments/default.yaml` and
`pdb.yaml` applied as a postsync hook. The normal path is therefore:

```bash
make helm-diff  SELECTOR=name=volcano
make helm-apply SELECTOR=name=volcano
```

Adopting an install helm does not own yet needs the ownership check skipped once:
`helmfile -l name=volcano apply --take-ownership`. Everything below is the
equivalent by hand, off the vendored tarball — still the way in if the download
from github times out, which is why that file is kept.

The `.tgz` here is the same chart 1.15.1 the helmfile release pulls. Step 1 is
optional; steps 2 and 3 are the install.

```bash
cd scheduler/volcano

# 1. render first and read it -- this is also the diff against what is live
helm template volcano ./volcano-1.15.1.tgz -n volcano-system -f values.yaml

# 2. install / upgrade / adopt
helm upgrade --install volcano ./volcano-1.15.1.tgz \
  -n volcano-system --create-namespace \
  -f values.yaml --take-ownership --wait --timeout 10m

# 3. the chart ships no PodDisruptionBudgets
kubectl apply -f pdb.yaml
```

Then check the one thing that fails silently — a values mistake drops the binpack
policy, and Volcano goes back to being blind to `nvidia.com/gpu` and spreading GPU
pods, with nothing in any log to say so:

```bash
kubectl -n volcano-system get cm volcano-scheduler-configmap \
  -o jsonpath='{.data.volcano-scheduler\.conf}' | grep 'binpack.resources'
```

`--take-ownership` is a stock helm flag (>= 3.17; both clusters run 3.21). It skips
the check for helm ownership annotations, so the same command covers a first install,
an ordinary upgrade, and **adopting a cluster where Volcano was installed with
`kubectl apply`**. Adoption is in place — the Deployments keep their uid and
creationTimestamp and roll like any other spec change; nothing is deleted. Verified on
a test cluster: the release reached REVISION 1 with PodGroups, PDBs, the binpack policy
and the running LWS all untouched, and the `kimi-k25` endpoint count never moved
across 36 samples taken through the rollout.

It is a no-op once the release exists, so it is safe to leave in the command.

Two things to know about adoption:

- The release name must stay `volcano`. The chart names the scheduler ConfigMap
  `<release>-scheduler-configmap`, and `volcano-scheduler-configmap` is the name the
  scheduler already reads.
- Fields that are live but not rendered by the chart are **kept, not removed** —
  helm has no previous release manifest to diff against, so it cannot tell a stale
  field from one owned by someone else. The `topologySpreadConstraints` that the old
  install added survive alongside the chart's `podAntiAffinity`. Same intent, same
  per-component selector, so the two are redundant rather than conflicting; a fresh
  install has only the affinity.

## HA

Upstream ships all three components as one replica with leader election off and no
resource requests. `values.yaml` changes that:

| Component | replicas | Mode |
| --- | --- | --- |
| `volcano-scheduler` | 2 | `--leader-elect=true`, active/standby |
| `volcano-controllers` | 2 | `--leader-elect=true`, active/standby |
| `volcano-admission` | 2 | stateless webhook server, both serve |

Plus a soft hostname spread (`custom.default_affinity`, a preferred
podAntiAffinity) and a `minAvailable: 1` PDB each. The spread is
soft on purpose — a hard constraint would leave the second replica
Pending on a small cluster rather than merely co-located, which is strictly worse.

`volcano-admission` is the one that earns this. Measured by scaling it to zero:

| | Affected? |
| --- | --- |
| An LWS already running | no — 60s of samples, endpoints and pod count unchanged |
| Ordinary pod creation | no — Volcano registers no pod webhook |
| **New LWS, group recreation, rollout** | **yes** — the LWS and its leader pod are created, the PodGroup is not, and reconcile returns at `CreatePodGroupIfNotExists` before the worker StatefulSet is reached. One pod, not two |
| Recovery | self-heals within 80s of admission coming back |

So it does not interrupt traffic; it freezes everything that needs a new pod,
including a group's own self-healing. Worth two replicas and a PDB, not worth
calling a cluster-wide outage.

The scheduler and controllers are singleton-by-design, so their second replica is a
warm standby, not extra throughput. Leader election needs `leases` in
`volcano-system`, which the upstream RBAC already grants to both service accounts.

Volcano coexists with `default-scheduler` and `binpack-scheduler` — it only owns pods
that name it in `spec.schedulerName`. Installing it is inert until a workload opts in.

Its webhooks are scoped to Volcano's own CRDs (`queues`, `jobs`, `cronjobs`,
`podgroups`, `hypernodes`) — there is no pod webhook, so a broken `volcano-admission`
cannot block ordinary pod creation. It *can* block PodGroup creation
(`failurePolicy: Fail`), which stalls LWS reconcile once gang scheduling is on.

## Packing

`custom.scheduler_config_override` in `values.yaml` carries the whole scheduling
policy. The part worth reading twice:

```yaml
- name: binpack
  arguments:
    binpack.resources: nvidia.com/gpu
    binpack.resources.nvidia.com/gpu: 10
```

**Volcano's binpack plugin scores cpu and memory only by default** —
`binpack.resources` is empty out of the box, so an unconfigured Volcano cannot
see `nvidia.com/gpu` and spreads GPU pods across nodes. Combined with
`nodeorder`'s spreading defaults in the same tier, which cancel binpack out if
left alone, the result is *worse* fragmentation than the `binpack-scheduler`
kube-scheduler profile this replaces. Same failure mode as kube-scheduler's own
default, which is why that profile had to name the resource explicitly too.

Two consequences worth being explicit about:

**One policy, cluster-wide.** `binpack-scheduler` was a kube-scheduler PROFILE,
so each workload picked its own via `spec.schedulerName`. Volcano has one policy
for everything it schedules — there is no per-workload knob. Queues carve up
quota, not scoring.

**It does not repack.** Packing decides where a *new* pod lands; it never moves a
running one. Migrating a Deployment to Volcano therefore changes nothing about
the existing layout: with `maxSurge: 1` each step has room for exactly one more
pod, so the replacement lands in whatever gap is open at that moment. Production
`fallback-modelforge-01` came out of its migration on the same six nodes it went
in on, pod for pod. The packing shows up later, when something new gets
scheduled — a scale-up, a pod recreation, a node coming back.

Changing the file needs a restart; the scheduler reads it once at startup:

```bash
kubectl -n volcano-system rollout restart deploy/volcano-scheduler
```

## Turning it on for LWS

Two changes, in this order:

1. **This directory** — install Volcano. The PodGroup CRD has to exist first.
2. **`nvidia/lws`** — `gangSchedulingManagement.schedulerProvider: volcano` in
   `default.yaml`, then `helm upgrade`. This is a controller-wide switch: the LWS
   controller starts creating one PodGroup per replica for **every** LWS in the
   cluster, not just the ones using Volcano. Harmless for the others — a PodGroup
   attached to pods the Volcano scheduler never sees imposes nothing.
3. **The workload** — `schedulerName: volcano` in both `leaderTemplate` and
   `workerTemplate`. This is a pod-template change, so it triggers a full rolling
   update of the LWS. Nothing else is needed: no PodGroup in the manifest, no
   annotation. The controller owns them, and `ownerReference` on the leader pod
   garbage-collects them.

Both silent-failure modes live in step 2: the RBAC for `podgroups` is only rendered
when `schedulerProvider` is set, and without it the controller creates no PodGroup
and no worker pod, logging a `forbidden` line nobody reads. Verify explicitly:

```bash
kubectl -n lws-system logs deploy/lws-controller-manager | grep -i "Gang scheduling enabled"
kubectl auth can-i create podgroups.scheduling.volcano.sh \
  --as=system:serviceaccount:lws-system:lws-controller-manager
kubectl -n <ns> get podgroups        # one per replica, minMember = LWS size
kubectl -n lws-system logs deploy/lws-controller-manager | grep -c "Reconciler error"
```

## Turning it on for an LWS that is already running

Step 2 above assumes the pods do not exist yet. On an LWS that is already serving it
breaks reconcile until every pod has been replaced:

```
ERROR Reconciler error {"controller":"pod","Pod":{"name":"kimi-k25-0","namespace":"kimi"},
 "error":"PodGroup.scheduling.volcano.sh \"\" is invalid: metadata.name: Required value"}
```

The PodGroup name comes from the leader pod's `scheduling.k8s.io/group-name`
annotation, which the LWS mutating pod webhook stamps on at CREATE. Pods that predate
the switch do not carry it, so the name is empty, the create fails, and reconcile
returns at `CreatePodGroupIfNotExists` — before the worker StatefulSet is created.
Traffic is unaffected (the data path does not go through the controller) but the LWS
stops self-healing, which is the worse failure to have silently.

Annotate the existing leader pods first — metadata only, no restart, inert until gang
is on — and the switch produces no error window at all:

```bash
NS=kimi; LWS=kimi-k25
for p in ${LWS}-0 ${LWS}-1; do
  GIDX=$(kubectl -n $NS get pod $p -o jsonpath='{.metadata.labels.leaderworkerset\.sigs\.k8s\.io/group-index}')
  REV=$(kubectl  -n $NS get pod $p -o jsonpath='{.metadata.labels.leaderworkerset\.sigs\.k8s\.io/template-revision-hash}')
  kubectl -n $NS annotate pod $p "scheduling.k8s.io/group-name=${LWS}-${GIDX}-${REV}" --overwrite
done
```

Only leader pods need it; the PodGroup is created off the leader.

## Two helm behaviours that bite here

`helm upgrade` changing only the ConfigMap **does not restart the controller** — the
Deployment spec is unchanged, so there is no new ReplicaSet and `rollout status`
returns success immediately while the controller still runs the old config. The chart
carries no ConfigMap checksum annotation. Always follow with:

```bash
kubectl -n lws-system rollout restart deploy/lws-controller-manager
```

And rolling back needs `--reset-values`. A bare `helm upgrade` reuses the previous
release's values, so gang stays on:

```bash
helm upgrade lws ./lws-chart-v0.9.0.tgz -n lws-system --reset-values
```

## Rolling back

Reverse order: drop `schedulerName` from the workload and let it roll back onto
`default-scheduler`, then `helm upgrade` LWS **with `--reset-values`**, then
`helm -n volcano-system uninstall volcano`. Removing Volcano while an LWS still
names it leaves those pods unschedulable.

Two things that are easy to get wrong here, both verified on a test cluster:

**A bare `helm upgrade` does not roll anything back.** With no `-f` and no
`--set`, helm reuses the previous release's user-supplied values, so the gang
stanza survives and the podgroups RBAC stays at 17 rules. Only `--reset-values`
clears them. Measured on both helm 3 and helm v4.3.0 -- the behaviour did not
change with the major version, which is worth knowing because the clusters here
moved to helm 4.

**Rolling back loses gang protection immediately.** The moment the pod template no
longer says `schedulerName: volcano`, surged pods go back to the plain scheduler —
and the half-placed group this whole directory exists to prevent comes back. On a
test cluster with only one free whole machine the rollback half-landed and stalled:
new leader bound, its worker Pending forever, 8 GPUs held by a group that cannot
serve. `maxUnavailable: 0` did keep traffic up throughout (1666 one-second samples,
endpoints never empty) — the rollback stalls, it does not drop requests.

So check free whole machines before rolling back, and do not start unless there are
at least `lws.size` of them.

**The same precondition applies to rolling forward.** A surge needs `lws.size` more
whole machines, and under gang the surged group takes nothing at all until it can
have all of them — so with fewer free it waits rather than half-landing. Safe, but
easy to misread as a failed rollout. Production hit exactly this and finished the
rollout with `maxSurge: 0` instead, which reuses the machines freed by the group
being replaced. That trades the spare capacity for a guaranteed half-capacity
window, and it needs no queued competitor at the moment of the swap (see below).

### Counting free whole machines is not counting free GPUs

Production's precheck said three free H100s; **one** was actually usable:

| node | GPU requests | why it was not usable |
| --- | --- | --- |
| node A | 0 | `unschedulable=true`, `Ready=Unknown`, `unreachable:NoExecute` — the node was down |
| node B | 0 | carried `descheduler.mark=true:NoSchedule`, and `allocatable` was 7, not 8 |
| node C | 0 | genuinely free |

A node counts only when all five hold: zero GPU requests, not cordoned, `Ready=True`,
`allocatable["nvidia.com/gpu"]` at full width, and no taint the workload does not
tolerate.

## Preemption

Volcano has a `preempt` action and job-level preemption — the gang-aware preemption
`scheduler/priority-classes.yaml` says a bigger priority number cannot buy. It is
not wired up, and the gap is wider than flipping `actions`. Measured on a test
cluster, four things all have to hold:

| # | Requirement | Why |
|---|---|---|
| 1 | `actions` gains `preempt`; `gang` / `drf` set `enablePreemptable: true` | the plugin config in `values.yaml` |
| 2 | **the preemptor's PODS carry a `PreemptLowerPriority` class** | Volcano reads `pod.spec.preemptionPolicy`, stamped at admission and immutable — so this means a new PriorityClass and a full pod recreation |
| 3 | **the victim sits in a lower tier** | same `value` does not preempt, and today every serving workload is `inference-prod` |
| 4 | **the victim is scheduled by Volcano** | Volcano cannot evict pods it does not own — a workload still on `binpack-scheduler` is invisible to it |

Requirements 2 and 3 both contradict what `scheduler/priority-classes.yaml`
currently states: that every live service belongs on `inference-prod`, and that
both inference tiers carry `preemptionPolicy: Never`. Changing either is a product
decision about which service gets sacrificed, not a scheduler tweak.

What the measurement looked like, in order:

```
preempt on, victim on Volcano and at batch-preemptible, but preemptor unchanged
  → 0 evictions. scheduler log:
    Preemptor <kimi/kimi-k25-1> failed to preempt Task,
      err: not eligible to preempt other tasks due to preemptionPolicy is Never

setting priorityClassName on the PodGroup instead
  → still 0. Volcano reads the POD's preemptionPolicy; the PodGroup's class does
    not reach it

pods recreated with a PreemptLowerPriority class
  → works: 4 victim pods evicted with
      Warning Evict  Pod is evicted, because of preempt
    and the waiting group admitted
```

One caveat even when it does work: preemption frees space **once**. The victim
Deployment's ReplicaSet recreates its pods immediately (20s in the measurement)
and they go fill whatever is open elsewhere.

Separately, and regardless of preemption: **the PodGroups the LWS controller
creates carry no `priorityClassName`** (v0.9.0 sets only `MinMember`,
`MinResources` and `Queue`). Volcano orders queued jobs by PodGroup priority, so
an LWS has no priority standing in the queue at all — the `inference-prod` on its
pods does not reach the scheduler's ordering.
