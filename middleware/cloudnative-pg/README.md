# CloudNativePG (HA PostgreSQL + PITR)

A shared PostgreSQL for the inference-stack workloads. Whoever needs it creates their own
database and account inside it. The first user is MiniMax H3 Server (database `minimaxh3` /
user `h3`).

What it provides:

- **High availability**: 1 primary and 2 standbys with automatic failover (measured: a new
  primary was elected 7s after the primary Pod was deleted)
- **Recovery to any point in time**: continuous WAL archiving + a daily base backup → the
  cluster's own Ceph RGW
- **Declarative databases and roles**: the `Database` / `DatabaseRole` CRDs
- **Minor version upgrades are rolled out by the operator**

**Ceph's three replicas protect against a lost disk or a lost machine, not against a mistyped
`DELETE` or an application writing bad data** — in that case all three replicas write the
error down together. PITR is the only way back, and that is the main value of this setup.

## Prerequisite: cert-manager (already in the clusters; not managed by this repo)

The barman-cloud backup plugin talks to the operator over CNPG-I (gRPC) with mutual TLS, and
the certificates are issued and rotated by cert-manager — the plugin chart renders an Issuer
plus 2 Certificates directly, so there is no option to run without cert-manager.

**Both clusters already have it installed; do not install it again** (a repeated
`helm install` will override the existing version):

| Cluster | Version | Installed on |
|---|---|---|
| Production cluster | v1.21.0 | 2026-07-28 |
| Test cluster | v1.21.1 | 2026-09-07 |

To install it yourself on a brand-new cluster:

```bash
helm upgrade --install --namespace cert-manager --create-namespace \
     cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.1 \
     --set crds.enabled=true --set crds.keep=true
```

`crds.enabled` must be on: cert-manager does not install the CRDs by default, and without them
the plugin's Issuer/Certificate fail to apply (`no matches for kind`).

## Install

The order cannot be changed (the Cluster needs the plugin's CRDs):

```bash
cd middleware/cloudnative-pg
make install                      # 1. operator + barman-cloud backup plugin
make app-secret                   # 2. application credentials (see below)
make cluster-dry && make cluster  # 3. bucket + ObjectStore + Cluster
make status                       # wait for 3/3 healthy
make backup-now                   # 4. take a base backup right away (do not skip; see below)
```

**Step 4 cannot be skipped**: the first automatic base backup only happens at 03:00 that day,
and until then there is nothing but continuous WAL archiving — and **WAL without a base backup
is orphaned**. PITR needs "one base backup plus the WAL replayed from it"; without the former
there is nothing to recover. Between the install and the first automatic backup, this database
effectively has no usable backup.

```bash
kubectl -n middleware get backup   # wait for phase=completed (about 2 minutes)
```

`make install` = `setup` (operator) + `plugin` (backup plugin). Their order is fixed and they
are always run together at install time; to upgrade only the plugin later, `make plugin` on its
own still works.

`make app-secret` creates the application credentials used by the CNPG bootstrap (`h3` by
default; change `APP_USER`). Password source: **explicitly passed in > randomly generated**.

```bash
APP_PASSWORD=xxx make app-secret   # an existing workload keeping its original password
make app-secret                    # fresh deployment, random 24 characters
```

**Do not add a "copy from some existing Secret in the cluster" branch** — when the name
collides with an unrelated Secret it silently reuses someone else's password, and the output
gives no sign of it. If you want to keep a password, pass it explicitly.

Skipped if it already exists: changing this Secret after initdb does **not** change the
password inside the database, it only makes the Secret and the database diverge and the
application's authentication fail.

This Secret's name is **deliberately the same as the RW Service name, `cnpg-rw`**: the H3
chart's `database.fromSecret.name` is a single field that means both "where to read the
password from" and "which host to connect to", and if the two names differ it cannot assemble
a correct DSN. With the names matching, the H3 side only needs:

```yaml
database:
  fromSecret:
    name: cnpg-rw
    passwordKey: password
```

and its chart needs no change. (The Secrets CNPG creates itself are `cnpg-{ca,replication,server}`,
which do not take `-rw`.)

⚠️ This Secret is **only read during the first initdb**; changing it after the database is
created does not change the password inside the database.

`make cluster-dry` is a server-side dry-run: it really does run the CRD validation and the
webhooks, so warnings about deprecated fields already show up at this step.

## Why `cluster/` is a hand-written CR rather than the official cluster chart

The operator and the backup plugin both use the **official charts** (referenced by OCI URL in
the Makefile, not vendored into the repo), and `overrides.yaml` / `plugin-overrides.yaml` are
the values for them.

There is also an official chart for the database instance itself
(`oci://ghcr.io/cloudnative-pg/charts/cluster`), but it is **not used**, for the reason
upstream states on the first screen of its own README:

> **Warning**
> ### This chart is under active development.
> ### Advised caution when using in production!
>
> This is an opinionated chart that is designed to provide **a subset of** simple, stable and
> safe configurations. It is **not designed to be a one size fits all solution**. If you need a
> more complicated setup we strongly recommend that you [write your own manifest].

It is also still at v0.8.1 (pre-1.0). Our setup falls exactly into the "more complicated" case
it describes: backups through the plugin instead of in-tree, the PG major version pinned
explicitly, credentials specified at bootstrap, a separate WAL disk, and a PodMonitor that
needs particular selector labels. So a hand-written CR is the path upstream recommends, not a
way around the official chart.

(The shape matches `observability/prom-stack`: official chart plus overrides, with the
workload-side CRs — `alerts/*.yaml` there — hand-written and applied with kubectl.)

## Why backups go through the plugin instead of `spec.backup.barmanObjectStore`

Both paths still exist in CNPG 1.30, but the in-tree one **will be removed entirely in
1.31.0**, and the webhook already warns at apply time:

```
Warning: Native support for Barman Cloud backups and recovery is deprecated and will be
completely removed in CloudNativePG 1.31.0. Found usage in: spec.backup.barmanObjectStore.
```

Writing it in-tree would mean taking on technical debt on the day it goes live, so the plugin
is used directly: one more Deployment in exchange for a migration that would otherwise be
inevitable.

For the same reason `spec.monitoring.enablePodMonitor` is also deprecated, and the PodMonitor
is managed by `cluster/podmonitor.yaml` instead.

## Connecting

Three Services, chosen by purpose. **Do not connect to a Pod directly** (the primary moves):

| Service | Purpose |
|---|---|
| `cnpg-rw.middleware.svc` | primary, read-write — this is the one workloads use |
| `cnpg-ro.middleware.svc` | round-robin over read-only replicas |
| `cnpg-r.middleware.svc`  | round-robin over any instance |

The password is generated by CNPG and is not kept in git. To get the application connection
string:

```bash
# The connection string looks like (the password is decided by make app-secret; see the "Install" section):
#   postgresql://h3:<pw>@cnpg-rw.middleware.svc.cluster.local:5432/minimaxh3
#
# ⚠️ Once bootstrap.initdb.secret is set, CNPG does **not** generate the cnpg-app Secret
#    — it uses the cnpg-rw we gave it. Reading cnpg-app returns NotFound.
kubectl -n middleware get secret cnpg-rw -o jsonpath='{.data.password}' | base64 -d; echo
```

## Backup bucket

`cluster/bucket.yaml` requests the bucket declaratively through rook's `ceph-bucket`
StorageClass, and rook correspondingly generates a Secret of the same name
(`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) and a ConfigMap (`BUCKET_NAME` / `BUCKET_HOST`).

Use `bucketName` rather than `generateBucketName`: the latter appends a random uuid, while the
`ObjectStore`'s `destinationPath` can only hold a literal, so any mismatch has to be filled
back in by hand every time.

To trigger a base backup manually (to verify the archiving path, or to keep one before taking
the database offline):

```bash
make backup-now
kubectl -n middleware get backup
```

## When deleting and recreating: clear the old archives out of the bucket first

A first-time install will not hit this. But deleting the Cluster and recreating it against the
same bucket will: before its first archive, barman runs
`barman-cloud-check-wal-archive`, which requires the destination to **be empty** (to stop two
clusters from overwriting each other's WAL), and a new instance that sees WAL left behind by
the previous generation **refuses to archive, permanently**:

```
ERROR: WAL archive check failed for server cnpg: Expected empty archive
archived_count=0  failed_count=216
pg_wal/archive_status/*.ready piled up to 278 files
```

**The symptom is extremely well hidden**: the Cluster still reports `Ready=True`, all three
Pods are green, and application reads and writes work fine; only the single
`ContinuousArchiving` condition is False. But WAL only leaves and never arrives, so the local
WAL disk climbs steadily (measured at 45% and still rising), and **a full disk = PostgreSQL
stops accepting writes = the workload goes down**.

Cleanup:

```bash
# Run on the jump host (vllm repo)
bash tools/cnpg/purge_stale_wal_archive.sh              # first, see what would be deleted
bash tools/cnpg/purge_stale_wal_archive.sh --apply cnpg # delete that prefix
```

Item 6 of the verification script checks `ContinuousArchiving`, the **pending-archive backlog**
and the **WAL disk usage** together — looking only at `archived_count/failed_count` is not
enough.

## Explicit boundaries

- **Data disk 50Gi / WAL disk 10Gi; keep an eye on usage.** On the test cluster, 1923 tasks
  used 2.1GB (about 1.1 MB per task, because the task table inlines large fields), so 50Gi
  ≈ 45000 tasks. `ceph-block` has `allowVolumeExpansion=true`, so changing
  `spec.storage.size` and applying is enough to **expand online** (CNPG rolls the expansion
  out instance by instance, with no interruption to the workload). But **do not wait until it
  is full** — a full PostgreSQL data disk stops writes outright. Adding a disk-usage alert to
  the monitoring is recommended.
- **Keep `instances` at 3; do not drop to 2.** With 2 replicas, any node maintenance leaves
  the cluster temporarily without a standby that can be promoted.
- **A separate disk for WAL.** When it shares the data disk, a WAL spike can fill the data
  disk, and a full PostgreSQL data disk = writes stop outright.
- **Do PVCs survive `kubectl delete cluster`?** They do not. CNPG's PVCs are owned by the
  Cluster, so deleting the Cluster deletes the data disks with it. To really take it offline,
  run `make backup-now` first and confirm the backup is Completed.

## Verified (test cluster, 2026-09-07)

All 11 items have measured values, not "the configuration looks right":

| # | Item | Measured |
|---|---|---|
| 0 | **Not claimed by another Service** | no crosstalk (see the pitfall in the previous section) |
| 1 | Topology | 3/3, cnpg-1 primary / cnpg-2 cnpg-3 replica |
| 2 | Anti-affinity | the 3 instances are on 3 different nodes |
| 3 | Version | PostgreSQL 16.10 |
| 4 | Database/role | `minimaxh3` owner=`h3`, the `pg-app` connection string works |
| 5 | Streaming replication | pg-2 / pg-3 both `streaming async` |
| 6 | WAL archiving | archived=7 failed=0, `ContinuousArchiving=True` |
| 7 | Objects in the bucket | 19 objects / 5.16 MB |
| 8 | Prometheus | all 3 `cnpg_collector_up` series =1, all targets up |
| 9 | PVC | 6 of them (3× data 50Gi + 3× WAL 10Gi), owner=Cluster (deleting the Cluster deletes them too) |
| 10 | Failover | delete the primary Pod → a new primary elected in **7s**, writes to the new primary succeed, back to 3/3 automatically |

The verification script is `tools/cnpg/verify_cnpg_remote.sh` in the vllm repo (**run it
locally on the jump host**; writing it as `ssh "..."` eats the quotes in the embedded
python/jsonpath and returns empty silently).

Two pitfalls when looking up the evidence, both now baked into the script:

- **`radosgw-admin` must be given `--rgw-realm/--rgw-zonegroup/--rgw-zone=ceph-objectstore`.**
  This rook has no default realm (`realm list` shows an empty `default_info`, and the default
  zone is a different one called `default`), so without those arguments you query the wrong
  zone — `bucket list` returns `[]` and `bucket stats` reports `failure: (2002)`, which looks
  as if the bucket does not exist at all.
- **The Prometheus container is distroless**, with no `wget`/`curl`, so you cannot
  `kubectl exec` into it to run a query; use `port-forward` plus curl on your own machine.

Zero impact on the existing services throughout: the old `postgresql-0` had restart=0 and its
1873 rows of data intact, and all six H3 Pods had restart 0.
