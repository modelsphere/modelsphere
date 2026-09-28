# Air-gapped install

Installing this stack on a cluster with no outbound network: what the bundle
holds, how it is built and loaded, and the two modes a cluster can then use. The
rest of the deployment is unchanged and lives in
[helmfile-deploy.md](helmfile-deploy.md); `offline/README.md` is the short
version that travels with the payload.


`registry` and `chartRepo` only ever covered what *we* build. Everything else —
cilium, rook, the prometheus stack, the NVIDIA operators, lws, volcano — resolves
to its own upstream, and on our clusters reaches it through the containerd
mirror `network_accesslator.yaml` writes. That mirror is itself a network hop, so
it is not a way to install without one.

`registryMode` is the switch for a cluster that has no outbound network at all.
It cannot be inferred from the other two values: both are always set, so
"registry is configured" says nothing about whether the outside is reachable.

Both offline modes take **every chart from files**: `chartsDir` points at the
bundle's `charts/` directory, and a chart found there is used instead of one
from `chartRepo`. Nothing chart-shaped goes into the registry. helm does not go
through containerd, so a node's mirror would do nothing for a chart anyway.
The modes differ only in what happens to image addresses:

| | `rewrite` | `mirror` |
|---|---|---|
| What helm renders | `<registry>/cilium/cilium` | `quay.io/cilium/cilium`, unchanged |
| Where the redirect lives | the values files in this repo | `/etc/containerd/certs.d` on each node |
| Environment file | `registry` must point at the local registry | `registry` is left alone — it stays the public `4pdosc` |
| Node setup | `make setup-offline-node REGISTRY=… MODE=rewrite` | `make setup-offline-node REGISTRY=… MODE=mirror` |
| Digests charts pin | dropped (`useDigest: false` on sixteen cilium images) | kept |
| `kubeadm init` | `--image-repository <registry>` | plain — containerd redirects |
| Diff reads as | every image under the local registry | upstream addresses, as online |

One `offline-load` serves either, because it puts each image in under both
names. For third-party images the two agree — the path containerd asks a mirror
for is the path the rewrite rule produces, host stripped and rest kept. For the
images **we** build they do not: the rewrite rule replaces the whole source
prefix, so `harbor.internal/infra/autoconfig` becomes
`<registry>/autoconfig`, while a mirror asks for
`<registry>/infra/autoconfig`. A component pushed under only one of the two
names is an ImagePullBackOff in the other mode, against a registry that holds
the image under another name. The second push is a manifest; the blobs are
already there. Pick the mode per cluster, not per bundle.

A bundle is **not** built for a particular cluster's registry. `offline-bundle`
renders the `default` environment, whose addresses are the public ones — 4pdosc
for what we build, the real upstream host for everything else — and
`offline-load` puts them wherever the site's registry is. That is what lets one
bundle serve both modes and any site: under `mirror` our components go in as
`<registry>/4pdosc/<name>`, which is what a node asks docker.io's mirror for,
and the environment file keeps saying `4pdosc` exactly as it does online.

Rendering a cluster environment instead (`-e <cluster>`) bakes that cluster's private registry into the
image list, and that second name becomes `<registry>/infra/<name>` — right
only for a cluster whose `registry` is private. `mirror-hosts.txt` comes from the
same render, so it names whichever hosts that environment uses.

⚠️ **Name your engine in `offline/engine-images.txt`.** It is the one image no
render can infer -- sglang and vllm are upstream projects and a site runs its
own build of one, at whatever address its `models:` entry gives the chart (see
models/examples/sglang-qwen.yaml). Put
that same address in `engine-images.txt` and two things follow: the bundle
carries the image, and its host joins `mirror-hosts.txt` so an air-gapped node
redirects it like any other. Leave it out and `mirror` sends the node to that
address for real -- which works on a host that happens to reach it, and fails on
one that does not.

⚠️ Those are upstream REGISTRY hostnames, not machines -- the inventory holds
the machines. The list is derived, not configured: `offline-bundle` reads every
address in the image list and writes the distinct hosts, so it already covers
wherever a site's own images live.

A model's four sidecars -- hang-watcher, CART and CART's two -- do **not** bring
their chart's host into that list. The sglang chart pins them at a private registry on
purpose (its values say why: the subchart's public defaults would leave those
pods in ImagePullBackOff on a cluster with no outbound network), but
`models/images.yaml.gotmpl` names them under this environment's `registry`
instead of inheriting those addresses, and the bundle stores them the same way.
A bundle built from the public `default` environment therefore holds them as
`4pdosc/...`, and that host never enters `mirror-hosts.txt` on their account.

`mirror_hosts` set where ansible reads variables overrides the file, which is
the escape hatch for a list that is wrong for some reason -- not the normal
path.

⚠️ Three of our charts are not published publicly yet (`alert-webhook`,
`condition2taint`, `llm-canary-operator`), so until they are, the chart half of
a default render needs the internal repo — `--set
chartRepo=https://harbor.internal/chartrepo/infra`, which changes nothing
about the image addresses.

`rewrite` is the one to reach for by default — what the cluster will pull is
visible in `helmfile diff`, with nothing depending on node state. `mirror` is
worth it when the charts' digests matter, when the environment file must stay
identical to the online one, or when a registry is already mirrored for other
reasons.

`mirror` has one sharp edge `rewrite` does not: two upstreams whose repository
path is identical become one repository in the registry, because a plain
registry ignores the `?ns=<upstream>` containerd sends. Nothing
downstream reports it — the pod pulls the other project's image. `offline-bundle`
refuses to build such a list rather than leave it to be discovered later.

### The naming rule

Third-party images drop their upstream host and keep the rest of the path:

```
quay.io/cilium/cilium   ->   <registry>/cilium/cilium
```

That holds as long as each org in the list comes from exactly one host. What
stays possible is a chart moving to a different registry without changing its
path — two internal copies would then collide silently, so check for that when
bumping charts.

Our own images have no path of their own — the charts render them as
`<registry>/<name>` — so the **whole** source prefix is replaced, host and
project both:

```
harbor.internal/infra/autoconfig   ->   <registry>/autoconfig
```

Stripping only the host would land them at `<registry>/infra/autoconfig`,
one segment away from the address the cluster asks for. That mismatch is
invisible until a pod cannot pull, and it only appears once the target registry
differs from the source one — which is the case the whole feature exists for.
`offline-load` reads the source prefix from the bundle MANIFEST, where
`offline_bundle.sh` records it.

The retag rule is written twice on purpose — here and in the offline-images
values files; **change it in both places in the same commit.**

`kube-prometheus-stack` is the one chart with a real one-line lever,
`global.imageRegistry`, and it is used: it reaches the subcharts whose own
values the parent's per-component keys never did. Do not copy that shape
elsewhere — it is a convention of that chart family, not a Helm feature, and
rook, npd, lws, descheduler, gpu-operator and network-operator have no such key.

### Node packages, before any of this

The bundle carries container images and charts, not apt packages: a node with no
route out needs `kubelet` `kubeadm` `kubectl` `containerd.io` installed already,
or an apt source that serves them. One node publishing `registry-mirror/`'s
package cache over HTTP is enough, with a
`deb [trusted=yes] http://<that node>/llm-repo /` line on the others.

Then run the node-prep tags by what each one needs, rather than `make setup-all`,
which assumes every node can reach the internet:

```bash
make setup-k8s-online  LIMIT=<the nodes that do have a route out>
make setup-k8s-offline LIMIT=all      # downloads nothing
make setup-mirror      LIMIT=all
```

### The four steps

Nothing can be assumed present at the target site — not a registry, not helm,
not a container runtime. The payload lives in `offline/` (structure committed,
content ignored; see `offline/README.md`).

**Build, where the internet is reachable.** Behind a proxy that means two
separate settings: dockerd's (a drop-in under
`/etc/systemd/system/docker.service.d/`, then restart it — the daemon pulls,
not the shell) and helm's (`HTTPS_PROXY` in the environment, which helm does
not inherit from docker). With only the first, `helm pull
oci://registry.k8s.io/...` fails and prints nothing at all.

```bash
make offline-tools                                 # ~400 MB: kubeadm, kubelet,
                                                   # kubectl, containerd, runc,
                                                   # CNI plugins, helm, helmfile,
                                                   # helm-diff,
                                                   # the registry image, and the
                                                   # kubeadm control-plane list
make offline-bundle BUNDLE=offline ENV=<cluster> \
  ARGS='--set llmGateway.node=<node> --set llmGateway.hostPath=/mnt/disk0/bodylog-sinks'
```

**The engine is the one image no render can name.** Everything else in the
bundle comes out of a helmfile render, but a model service is not in any
environment -- it comes in from a `MODELS=` file on the command line, and a
bundle is built before anyone knows which models the site will run. So the
bundle covers a model's five images the other way round: the engine from the
list below, and the four sidecars read out of the engine chart's own
`values.yaml` in the bundle -- hang-watcher and CART at the versions that chart
pins, CART's `ha` and `reload` at `versions.autoconfig` from the environment,
since those two are autoconfig's.
Copy `offline/engine-images.txt.example` and name the ones that site runs. The
charts' own defaults are deliberately not used: they are `lmsysorg/sglang:latest`
and `vllm/vllm-openai:latest-cu129-ubuntu2404`, floating tags that match nothing
any cluster here runs.

Size matters here more than anywhere else: **one engine image is ~19 GB
compressed**, larger than everything else in the bundle put together. Model
weights are not in the bundle and are not a job for it.

**The sglang chart names three images no render lists.** The bundle reads them
out of the chart archive, so this is background, not a task — nothing to add to
`engine-images.txt` and nothing to override in a workload's values. With
`cart.enabled`, CART comes up with three sidecars the chart pins to a private registry in
its own values (`cart.image`, `cart.ha.image`, `cart.reload.image`);
`models/images.yaml.gotmpl` replaces those addresses with this environment's
`registry`, and the bundle carries them under the same name it will be asked
for. The versions differ in where they come from: `cart.image` keeps the tag
its chart pins, while `ha` and `reload` are autoconfig's sidecars and take
`versions.autoconfig` from the environment being built. Get that wrong and the
pod does not degrade — they are ordinary containers in the CART pod, so one
unpullable image keeps the whole pod down.

Carry **this repository** across, with `offline/` inside it. Every step below
is a `make` target, so the Makefile, `helmfile.yaml.gotmpl`, `environments/`,
the playbooks and `cni/` all have to be on site -- the bundle alone runs
nothing.

One machine on site is the **control machine**: it is where you type, and it
needs `ansible`, `kubectl`, `helm`, `helmfile` and this repository. The bundle
carries none of those. The nodes do not need them, so this is one machine to
prepare, not every node -- and note that a distribution's own `ansible` package
may be older than the version README asks for.

Then, on the air-gapped side, write the site's facts
once — `cp offline/site.env.example offline/site.env` and set `REGISTRY`.
Every step below reads it, so the registry address is written once rather than
in the three places that would otherwise each hold a copy of it (the
environment values, kubeadm's flag, and containerd's sandbox image).

**1. Tools.** `make offline-install-tools` — binaries, systemd units and a
containerd config into place. Nothing here can be assumed present, which is why
the registry image ships as a tool rather than as part of the image payload:
step 2 cannot start without it.

Check the target's glibc first: the pinned containerd (2.3.3) needs **glibc ≥
2.34**, so Ubuntu 22.04+ or RHEL 9+. On an older host the binary does not start
at all — on CentOS 7 (glibc 2.17): `GLIBC_2.32 / GLIBC_2.34 not found`. Drop
`CONTAINERD_VERSION` to a 1.7.x build for those.

**2. Registry, and load it.** Both read `offline/site.env`:

```bash
make offline-registry                              # one registry:3 container
make offline-load                                  # images, and kubeadm's
```

The registry holds images only. The charts stay as the `.tgz` files the bundle
carried and helm installs them from there, which is what `chartsDir` is for —
uploading them was a whole moving part (a path prefix so a chart and an image
sharing one OCI path did not overwrite each other, helm's separate credential
store, Harbor's `/api/charts` versus an OCI push) to hand back files the site
already had.

**2b. If the registry has credentials**, they are needed in two places that
share nothing with each other:

```bash
crane auth login <host>:5000 -u ... -p ...  # images, for offline_load.sh (or `docker login`: same file)
```
```yaml
# /etc/rancher/k3s/registries.yaml, or containerd's, for the cluster
configs:
  "<host>:5000":
    auth: { username: ..., password: ... }
```

Without the cluster-side entry, `crictl pull` fails with `no basic auth
credentials` while the load side is perfectly happy.

**3. Point everything at it.** Under `rewrite`, three values, no more:

```yaml
# environments/<cluster>.yaml — what helm renders
registry: <host>:5000
chartsDir: /root/bundle/charts     # where the bundle was carried to
registryMode: rewrite
```

**Register that file** under `environments:` in `helmfile.yaml.gotmpl`,
alongside `environments/default.yaml`, or helmfile never reads it. Nothing
reports this: unregistered, `registryMode` falls back to `upstream` and the
install reaches for the internet -- which passes in a room that still has a
network and fails in the one that does not.

`chartsDir`, not a `chartRepo` pointing at the registry: the load step puts no
charts there, so a `chartRepo: oci://<host>:5000/charts` is an address nothing
ever filled. `chartRepo` stays as it is and is simply not consulted for a chart
the directory already has.

```bash
# what the distribution pulls for itself -- kube-apiserver belongs to no chart
kubeadm init --image-repository <host>:5000     # or imageRepository: in the
                                                # kubeadm config file
k3s server --system-default-registry <host>:5000
```

⚠️ **Every node needs to trust that registry**, not just the one running it.
The addresses are all `<host>:5000/...` in this mode, and a plain-HTTP registry
is refused by containerd unless a `certs.d` entry says otherwise --
`offline_registry.sh up` writes one, but only on the machine it runs on. On
every other node, before it joins:

```bash
mkdir -p /etc/containerd/certs.d/<host>:5000
cat > /etc/containerd/certs.d/<host>:5000/hosts.toml <<EOF
server = "http://<host>:5000"

[host."http://<host>:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
systemctl restart containerd
```

A control plane that is also the registry host therefore comes up while every
other node joins and then fails to pull anything. `mirror` does not have this
gap -- its whole node-side config is a playbook that runs everywhere.

Under `mirror`, one address and one playbook — the nodes carry the redirect, so
`kubeadm init` and `registry:` are left exactly as they are online:

```yaml
# environments/<cluster>.yaml
chartsDir: /root/bundle/charts     # where the bundle was carried to
registryMode: mirror
```

```bash
# every node, including the ones kubeadm runs on, BEFORE kubeadm init
make setup-offline-node REGISTRY=<host>:5000 MODE=mirror BUNDLE=./offline
```

`BUNDLE=` here is a path on the **control machine**, not on the nodes: the
playbook reads the bundle's `mirror-hosts.txt` with an Ansible file lookup,
which always resolves locally. Point it at a bundle the nodes can see and the
run fails with `The 'file' lookup had an issue accessing the file
'…/mirror-hosts.txt'. file not found` -- naming a path that does exist on the
node you are configuring, which sends you to look on the wrong machine.

That playbook writes one `/etc/containerd/certs.d/<upstream>/hosts.toml` per
host in the bundle's `mirror-hosts.txt`, each pointing at the registry, and
deliberately without a `server =` line: that key is the upstream fallback, and
here it would turn a missing image into a long timeout — or, on a node with
partial network, into a silent pull from the internet, leaving the bundle
untested. It also overwrites what `make setup-mirror` writes (the public-cache
mirrors), so on an air-gapped cluster run this one last and not that one again.

There is a **third** address, and it belongs to neither of them: containerd
holds the sandbox (pause) image as a literal and asks for it by that name.
`offline_tools.sh install` stamps it from `REGISTRY`, using the pause version
out of kubeadm's own list so it matches what kubeadm's preflight expects. The
key differs by version — `sandbox_image` in containerd 1.x, and
`plugins."io.containerd.cri.v1.images".pinned_images.sandbox` in 2.x. Miss it
and every pod sits in ContainerCreating while kubeadm's images are all present,
which points nowhere near the cause.

Those control-plane images do **not** follow the host-stripping rule the charts
use. `kubeadm` asks for `<registry>/coredns`, while stripping the host from
`registry.k8s.io/coredns/coredns` gives `<registry>/coredns/coredns` — one
segment apart, and the cluster never comes up. `offline_load.sh` does not
compute those names: it asks kubeadm for both lists and pairs them line by
line, refusing to proceed if the lengths differ.

**4. Install**, with one flag added: `SKIP_DEPS=1` (or `--skip-deps` when
calling helmfile directly). helmfile refreshes every declared chart repository
before it renders, which fails with no outbound network even though the charts
are all on disk. Otherwise unchanged from an online cluster:

```bash
make helm-bootstrap ENV=<cluster> SKIP_DEPS=1
make helm-apply     ENV=<cluster> SKIP_DEPS=1
```

Read the diff before applying: anything still naming `quay.io`, `nvcr.io`,
`ghcr.io` or `registry.k8s.io` is a component the bundle missed — and after
step 3 those will fail loudly rather than quietly reaching upstream.

**5. A model goes in as a helmfile release**, not with `helm install`. The
online path installs an engine straight from the chart repository, which an
air-gapped cluster cannot reach; going through helmfile is also what puts the
model's five images through `registryMode`, the same rewrite every other image
in the stack gets:

```bash
make helm-apply ENV=<cluster> SELECTOR=tier=model \
  MODELS=models/examples/sglang-qwen.yaml SKIP_DEPS=1
```

The weights themselves are not in the bundle and never were: put them on the
node first, as [README step 8](../README.md#8-deploy-a-model) describes.

### One known gap: what values cannot reach

Rewriting addresses in values changes what the **Pod spec says**. It cannot
change what a controller asks for on its own.

Under `rewrite`, ceph-csi's operator creates its driver pods from
`quay.io/cephcsi` and four `registry.k8s.io/sig-storage` images *before* it
reads the image set it has been given, and reconciles them to the internal
addresses about five minutes later. On an air-gapped cluster those pods sit in
ImagePullBackOff for that interval and are then replaced — survivable, and
worth knowing about before someone watches it happen. On a host that can still
reach the public registries the first pull succeeds instead, and those five
upstream names stay in containerd next to their internal copies, same image ids
with two tags each, which nothing shows until the image list is read tag by tag.

Under `mirror` this five-minute gap does not happen at all: the operator's
compiled-in `quay.io/cephcsi` is an address the nodes already answer, so the
first pod starts from the bundle and the reconcile changes nothing visible.

What must not be done — in either mode — is to reach for a mirror of the
upstream names that keeps a `server =` fallback, the kind `make setup-mirror`
writes for public caches. That makes an image the bundle is MISSING succeed
quietly off the internet, which is the failure the bundle exists to prevent:
the install passes in a room that still has a network, and fails in the room
that does not. `make setup-offline-node` writes no fallback for exactly this
reason.

One caveat: dropping `server =` removes the *explicit* fallback, so a missing
image fails at once while the registry is up. It does not cut the upstream off
-- when the listed host does not answer at all (the registry stopped),
containerd still tries the namespace host itself, and on a node that still has
internet the pull comes from quay.io. Air-gapped that is a timeout rather than a
wrong pull, but "no fallback" describes the config, not the network.

### Where the addresses live

`registryMode: upstream` renders byte-for-byte what the repo rendered before the flag
existed — the offline values are separate files, pulled into `values:` only when
the flag is on:

| Release | File |
| --- | --- |
| `cilium` | `cni/overrides.yaml.gotmpl` (inline; that file is already a template) |
| `rook-ceph` | `ceph/rook-offline-images.yaml.gotmpl` |
| `rook-ceph-cluster` | `ceph/rook-cluster-offline-images.yaml.gotmpl` |
| `kube-prometheus-stack` | `observability/prom-stack/offline-images.yaml.gotmpl` |
| `node-problem-detector` | `observability/npd/offline-images.yaml.gotmpl` |
| `descheduler` | `observability/descheduler/offline-images.yaml.gotmpl` |
| `gpu-operator` | `nvidia/gpu-operator-offline-images.yaml.gotmpl` |
| `network-operator` | `nvidia/network-operator/offline-images.yaml.gotmpl` |
| `lws` | `nvidia/lws/offline-images.yaml.gotmpl` |
| `volcano` | `scheduler/volcano/offline-images.yaml.gotmpl` |

They are separate files rather than blocks appended to each `overrides.yaml`
because an overrides file may legitimately hold a Go-template expression meant
for something downstream — `observability/npd/overrides.yaml` carries one for
Prometheus. Renaming those to `.gotmpl` hands them to helmfile's template
engine, which resolves the undefined variable and blanks the annotation, or
fails the render. The same trap applies *inside comments*: helmfile renders the
whole file before any YAML is parsed, which is why the comments in these files
describe such expressions instead of quoting one.

### Subcharts are where this goes wrong

Three of these charts name images the parent's own keys do not reach, and the
values file does not show it:

| Chart | Subchart | Key |
| --- | --- | --- |
| `kube-prometheus-stack` | `grafana`, `kube-state-metrics`, `prometheus-node-exporter` | `<subchart>.image.registry` — five of its ten images |
| `gpu-operator` | `node-feature-discovery` | `node-feature-discovery.image.repository` |
| `rook-ceph` | `ceph-csi-operator` | `ceph-csi-operator.controllerManager.manager.image.repository` |
| `network-operator` | `sriov-network-operator` | a flat `images:` map of twelve full addresses |

Setting only the parent keys leaves a cluster that pulls from the public
internet and looks fine until it tries. When bumping any of these charts, render
it and check the addresses rather than diffing the values file.

Two chart-specific shapes worth knowing:

- **cilium pins by digest.** `useDigest` defaults to `true` on all sixteen of
  its images, and a digest overrides `repository` — so each entry needs
  `useDigest: false` alongside it or the rewrite is silently ignored. It is the
  only chart here that does this.
- **gpu-operator splits the address.** Its ClusterPolicy carries `repository:`,
  a bare `image:` name and `version:` on three separate lines, so grepping
  rendered `image:` lines for this chart reports names, not addresses.
  `offline-bundle` reassembles the three; a check written by hand has
  to read all three fields.
- **network-operator's sriov images come from the parent, not the subchart.**
  The `sriov-network-operator` subchart defaults its `images:` map to
  `ghcr.io/k8snetworkplumbingwg/*` untagged, and the parent overrides nine of
  them to `nvcr.io/nvidia/mellanox/*:network-operator-v26.4.1`. The parent's
  values are what deploys. Naming the subchart's defaults changes the host and
  drops the tag — and an untagged address carries no version, so the bundle
  leaves it out and a prefix check then passes over nine missing images. The
  metrics exporter is the one sriov image the parent does not pin, so
  `nvidia/network-operator/overrides.yaml` pins it at v1.2.0 itself, on the
  online path as well as the air-gapped one.

### What the bundle does not cover

- Images referenced by workloads rather than by this helmfile — inference
  engines, anything under `gateway-api/`.
- Components whose flags are off. The image list is derived from a render, and
  a render only sees what is switched on. Turning a feature on later means
  rebuilding the bundle. cilium is the one exception: the bundle renders it a
  second time on its own and includes it regardless of the flag, because an
  air-gapped cluster needs its CNI before anything else.
- Addresses that carry no tag upstream. There are none left today, but the
  script lists any it finds on stderr rather than deciding silently: such an
  address still pulls — no tag means `:latest` — yet it names no version, so
  bundling it would pin one on the chart's behalf. Pin it in our own values
  instead, the way `nvidia/network-operator/overrides.yaml` does.
- The ClusterPolicy's kernel-module images — `driver`, `gdrcopy` and `gds`.
  Their `version` field is a base version only; the gpu-operator appends the
  node's OS at run time, so the render never contains a complete address and
  the three fields cannot be assembled into one. NGC publishes no bare
  `580.126.20` tag for `nvidia/driver` at all, and none for gdrdrv or nvidia-fs
  either — the real tags read `580.126.20-ubuntu22.04`, `v2.5.2-rhcos4.16` and
  so on. The script reports these rather than bundling an address that exists
  nowhere.

  None of them is pulled on our clusters today: `gdrcopy` and `gds` render
  `enabled: false` on all three, and the driver DaemonSet sits at DESIRED=0
  because every GPU node is labelled `nvidia.com/gpu.deploy.driver=pre-installed`.
  Before enabling one on an isolated cluster, mirror it by hand at the suffix
  its nodes call for — every GPU node here runs Ubuntu 22.04, so `-ubuntu22.04`,
  with a single Kylin V10 node as the exception.

  Filtering these out by `enabled` does not work: `driver` renders
  `enabled: true` and is held off by the node label rather than by the chart,
  while `dcgm` and `nodeStatusExporter` render `enabled: false` yet name
  addresses that other, enabled components pull.
- Example addresses quoted in CRD `description:` prose. Three today, all from
  rook: `quay.io/ceph/ceph:<tag>`, `quay.io/ceph/nvmeof:1.5` and
  `quay.io/repository/ceph/ceph`. The first is a literal `<tag>`, which is why
  CRDs are scraped for real image fields only.
- Releases switched off for the run. One that is off renders no objects, so its
  images are absent from the list; `offline_bundle.sh` names them rather than
  letting the count come up short.

  **alert-webhook is the live case.** It hard-fails at template time unless
  `webhook.urls` is supplied, and `observability/alert-webhook/config.yaml.gotmpl`
  ships that key as an empty placeholder for the environment to fill. So the
  bundle is normally built with it disabled, and then lacks its server image,
  `harbor.internal/infra/alert-webhook-server:260828-fe78`. Set
  `alertWebhook.urls` in the environment to have it bundled, or mirror it by
  hand. `--set webhook.urls.X=...` does NOT work -- the placeholder is null and
  helm cannot nest a key under a null. The chart's other image is the `helm
  test` probe; offline it is pointed at the busybox the bundle already carries
  for prom-stack rather than the bare `busybox:1.37` the chart defaults to.

A reference with no registry host is expanded rather than dropped:
`busybox:1.37` means `docker.io/library/busybox:1.37`. The expansion is gated
on the document kind, because a ClusterPolicy writes the name half of a
repository/image/version triple as a bare `image: driver`, and expanding those
invents addresses that exist nowhere.
- The NVIDIA driver itself, if you ever set `driver.enabled` so that the
  operator installs it. `usePrecompiled: false` means the driver container
  compiles the module on the node and needs kernel headers from a distro apt
  mirror — a second network dependency that no registry covers, and
  `driver.repoConfig.configMapName` is empty. Our clusters run a host driver
  (`nvidia.com/gpu.deploy.driver: pre-installed`, driver DaemonSet DESIRED=0),
  so this path is currently unused.

### What is still unproven

- **`registryMode: mirror`, as a whole install.** `kubeadm init` plus a full
  `helmfile apply` in this mode has not been done end to end; the mirror
  mechanism on its own is covered by
  `tools/offline-install/verify_mirror_mode.sh` (in the vllm repo).
- **rook-ceph-cluster.** The CephCluster and its OSDs are untested here, which
  needs three nodes with a spare raw device.
- **A bundle built from true upstreams in one pass.** `*.pkg.dev` (which serves
  the lws chart) and GitHub's release CDN need an internal proxy, so a build
  host without one comes up short a chart.
- **Multi-node.** Nothing in the flag is node-count dependent, and the `join`
  half of kubeadm is not covered here anyway.
- **The distribution's own images are not this bundle's job.** k3s ships an
  airgap tarball; a kubeadm cluster needs `kubeadm config images list` mirrored
  -- which `offline_tools.sh` does fetch and `offline_load.sh` does push, and
  `kubeadm init --image-repository` then pulls from there.
- **Pull credentials.** k3s authenticates to a registry node-wide through
  `registries.yaml`, so no imagePullSecret is needed; a kubeadm cluster wants
  the containerd `registry.configs` equivalent or a dockerconfigjson Secret per
  namespace. Neither has been exercised against a registry that requires auth.

## Why crane, and why the full index

`docker pull` + `docker save` rewrites the manifest before the bundle is
carried anywhere: docker resolves a multi-arch index to one platform and saves
that, so the digest a chart pins is no longer resolvable in the target registry.
cilium pins sixteen images by digest, so under `mirror` every one of them would
fail to resolve. crane copies OCI layouts: same digest in, same digest out.

Two more reasons the docker path cannot be used: a digest-pinned image comes
back from `docker load` with no name at all, so `docker tag` fails; and
`docker save` on a host using the containerd snapshotter writes a manifest-only
tarball a few KB in size for a 143 MB image -- valid tar, and silently useless.

The full index is what preserves the digest, and it is expensive: `pause:3.10`
is 553 MB as an index against roughly 700 KB for one platform. So an image a
chart pins BY DIGEST keeps its index, and everything else is fetched for
`BUNDLE_PLATFORMS` only -- one platform by default, `"linux/amd64,linux/arm64"`
for a cluster with arm64 nodes.

## One build per output directory

A full run takes tens of minutes, which makes it tempting to start a second one
into the same output directory. Do not: two `crane pull` processes write the
same `<image>.part` directory and both append to one log, neither run fails, and
the bundle is simply wrong.

The lock is a `mkdir` with the pid inside, not `flock`, which does not exist on
macOS. A lock whose holder is gone is taken over rather than left forever.

## An empty layout is not an image

crane writes `oci-layout` and `index.json` before it fetches any blob, so a pull
that is killed leaves a directory that passes every cheap check: an interrupted
layout sits in the bundle with `"manifests": []` and counts as done, and nothing
says otherwise until a node tries to pull it, in the room with no network.

`tools/offline-install/verify_layouts.sh` (in the vllm repo) walks every layout
and checks each blob exists at the size its manifest claims. A check that only
looks for missing blobs passes an empty layout, since no manifests means no
blobs to find missing.
